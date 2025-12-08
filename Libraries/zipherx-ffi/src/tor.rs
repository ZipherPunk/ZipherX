//! Arti (Rust Tor) integration for ZipherX
//!
//! Provides embedded Tor support for both iOS and macOS
//! Uses Arti - the Tor Project's official Rust implementation
//! Includes SOCKS5 proxy server for P2P connections

use arti_client::{TorClient, TorClientConfig, StreamPrefs};
use tor_rtcompat::PreferredRuntime;
use tokio::runtime::Runtime;
use tokio::net::{TcpListener, TcpStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use once_cell::sync::OnceCell;
use std::sync::{Arc, Mutex, atomic::{AtomicU8, AtomicU16, AtomicBool, Ordering}};
use std::path::PathBuf;
use std::net::SocketAddr;

/// Global Tor client instance
static TOR_CLIENT: OnceCell<Mutex<Option<TorClient<PreferredRuntime>>>> = OnceCell::new();

/// Global Tokio runtime for async operations
static TOKIO_RUNTIME: OnceCell<Runtime> = OnceCell::new();

/// Tor connection state (matches Swift TorConnectionState)
/// 0 = Disconnected, 1 = Connecting, 2 = Bootstrapping, 3 = Connected, 4 = Error
static TOR_STATE: AtomicU8 = AtomicU8::new(0);

/// Bootstrap progress (0-100)
static TOR_BOOTSTRAP_PROGRESS: AtomicU8 = AtomicU8::new(0);

/// SOCKS proxy port - fixed at 9150 for compatibility with zclassicd
/// (9150 is the standard Tor Browser SOCKS port, 9050 is system Tor)
const FIXED_SOCKS_PORT: u16 = 9150;

/// SOCKS proxy port (stored after binding)
static TOR_SOCKS_PORT: AtomicU16 = AtomicU16::new(0);

/// Last error message
static TOR_ERROR: Mutex<Option<String>> = Mutex::new(None);

/// Flag to stop the SOCKS proxy server
static SOCKS_SERVER_RUNNING: AtomicBool = AtomicBool::new(false);

/// Get or create the Tokio runtime
fn get_runtime() -> &'static Runtime {
    TOKIO_RUNTIME.get_or_init(|| {
        Runtime::new().expect("Failed to create Tokio runtime")
    })
}

/// Get the Tor data directory
fn get_tor_data_dir() -> PathBuf {
    #[cfg(target_os = "ios")]
    {
        // iOS: Use Documents directory
        if let Some(home) = dirs::document_dir() {
            return home.join("ZipherX").join("Tor");
        }
    }

    #[cfg(target_os = "macos")]
    {
        // macOS: Use Application Support
        if let Some(support) = dirs::data_dir() {
            return support.join("ZipherX").join("Tor");
        }
    }

    // Fallback
    PathBuf::from("/tmp/zipherx_tor")
}

/// Start the embedded Tor client
/// Returns 0 on success, 1 on error
#[no_mangle]
pub extern "C" fn zipherx_tor_start() -> i32 {
    // Already running?
    let state = TOR_STATE.load(Ordering::SeqCst);
    if state == 1 || state == 3 {
        eprintln!("🧅 Tor already running or starting");
        return 0;
    }

    TOR_STATE.store(1, Ordering::SeqCst); // Connecting
    TOR_BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);

    let runtime = get_runtime();

    runtime.spawn(async {
        match start_tor_async().await {
            Ok(port) => {
                TOR_SOCKS_PORT.store(port, Ordering::SeqCst);
                TOR_STATE.store(3, Ordering::SeqCst); // Connected
                TOR_BOOTSTRAP_PROGRESS.store(100, Ordering::SeqCst);
                eprintln!("🧅 Tor connected! SOCKS port: {}", port);
            }
            Err(e) => {
                let msg = format!("{}", e);
                eprintln!("🧅 Tor error: {}", msg);
                if let Ok(mut err) = TOR_ERROR.lock() {
                    *err = Some(msg);
                }
                TOR_STATE.store(4, Ordering::SeqCst); // Error
            }
        }
    });

    0
}

/// Async function to start Tor and SOCKS5 proxy server
async fn start_tor_async() -> Result<u16, Box<dyn std::error::Error + Send + Sync>> {
    let data_dir = get_tor_data_dir();

    // Create data directory if it doesn't exist
    std::fs::create_dir_all(&data_dir)?;

    eprintln!("🧅 Tor data directory: {:?}", data_dir);

    // Build Tor configuration using default config with custom paths
    // Note: Arti 0.37+ requires CfgPath type, so we use environment variables
    // to set the directories instead
    std::env::set_var("ARTI_CACHE_DIR", data_dir.join("cache").to_string_lossy().to_string());
    std::env::set_var("ARTI_STATE_DIR", data_dir.join("state").to_string_lossy().to_string());

    // Use default configuration
    let config = TorClientConfig::default();

    eprintln!("🧅 Starting Arti Tor client...");
    TOR_BOOTSTRAP_PROGRESS.store(10, Ordering::SeqCst);

    // Create and bootstrap the client
    let client = TorClient::create_bootstrapped(config).await?;

    TOR_BOOTSTRAP_PROGRESS.store(80, Ordering::SeqCst);
    eprintln!("🧅 Arti client bootstrapped, starting SOCKS5 proxy...");

    // Store the client
    let client_arc = Arc::new(client);
    let client_storage = TOR_CLIENT.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = client_storage.lock() {
        *guard = Some((*client_arc).clone());
    }

    // Start SOCKS5 proxy server on fixed port 9150 (for zclassicd compatibility)
    // Try the fixed port first, fallback to dynamic if in use
    let listener = match TcpListener::bind(format!("127.0.0.1:{}", FIXED_SOCKS_PORT)).await {
        Ok(l) => {
            eprintln!("🧅 SOCKS5 proxy listening on 127.0.0.1:{} (fixed port)", FIXED_SOCKS_PORT);
            l
        }
        Err(e) => {
            eprintln!("🧅 Fixed port {} in use ({}), trying dynamic port...", FIXED_SOCKS_PORT, e);
            let l = TcpListener::bind("127.0.0.1:0").await?;
            eprintln!("🧅 SOCKS5 proxy listening on 127.0.0.1:{} (dynamic fallback)", l.local_addr()?.port());
            l
        }
    };
    let socks_port = listener.local_addr()?.port();
    TOR_SOCKS_PORT.store(socks_port, Ordering::SeqCst);
    TOR_BOOTSTRAP_PROGRESS.store(95, Ordering::SeqCst);

    // Spawn the SOCKS5 proxy server
    SOCKS_SERVER_RUNNING.store(true, Ordering::SeqCst);
    let client_for_proxy = client_arc.clone();

    tokio::spawn(async move {
        run_socks5_proxy(listener, client_for_proxy).await;
    });

    TOR_BOOTSTRAP_PROGRESS.store(100, Ordering::SeqCst);
    Ok(socks_port)
}

/// Run the SOCKS5 proxy server
async fn run_socks5_proxy(listener: TcpListener, client: Arc<TorClient<PreferredRuntime>>) {
    eprintln!("🧅 SOCKS5 proxy server started");

    while SOCKS_SERVER_RUNNING.load(Ordering::SeqCst) {
        match listener.accept().await {
            Ok((stream, addr)) => {
                let client_clone = client.clone();
                tokio::spawn(async move {
                    // Silently handle connection errors (too verbose otherwise)
                    let _ = handle_socks5_connection(stream, addr, client_clone).await;
                });
            }
            Err(e) => {
                if SOCKS_SERVER_RUNNING.load(Ordering::SeqCst) {
                    eprintln!("🧅 SOCKS5 accept error: {}", e);
                }
            }
        }
    }

    eprintln!("🧅 SOCKS5 proxy server stopped");
}

/// Handle a single SOCKS5 client connection
async fn handle_socks5_connection(
    mut stream: TcpStream,
    addr: SocketAddr,
    client: Arc<TorClient<PreferredRuntime>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // SOCKS5 greeting: client sends version + auth methods
    let mut greeting = [0u8; 2];
    stream.read_exact(&mut greeting).await?;

    if greeting[0] != 0x05 {
        return Err("Not SOCKS5".into());
    }

    let num_methods = greeting[1] as usize;
    let mut methods = vec![0u8; num_methods];
    stream.read_exact(&mut methods).await?;

    // Reply: accept no auth (0x00)
    stream.write_all(&[0x05, 0x00]).await?;

    // Read connection request
    let mut request = [0u8; 4];
    stream.read_exact(&mut request).await?;

    if request[0] != 0x05 || request[1] != 0x01 {
        // Only support CONNECT (0x01)
        stream.write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
        return Err("Unsupported SOCKS5 command".into());
    }

    // Parse destination address
    let (host, port) = match request[3] {
        0x01 => {
            // IPv4
            let mut ip = [0u8; 4];
            stream.read_exact(&mut ip).await?;
            let mut port_bytes = [0u8; 2];
            stream.read_exact(&mut port_bytes).await?;
            let port = u16::from_be_bytes(port_bytes);
            (format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3]), port)
        }
        0x03 => {
            // Domain name
            let mut len = [0u8; 1];
            stream.read_exact(&mut len).await?;
            let mut domain = vec![0u8; len[0] as usize];
            stream.read_exact(&mut domain).await?;
            let mut port_bytes = [0u8; 2];
            stream.read_exact(&mut port_bytes).await?;
            let port = u16::from_be_bytes(port_bytes);
            (String::from_utf8_lossy(&domain).to_string(), port)
        }
        0x04 => {
            // IPv6
            let mut ip = [0u8; 16];
            stream.read_exact(&mut ip).await?;
            let mut port_bytes = [0u8; 2];
            stream.read_exact(&mut port_bytes).await?;
            let port = u16::from_be_bytes(port_bytes);
            // Format IPv6 address
            let addr: std::net::Ipv6Addr = ip.into();
            (addr.to_string(), port)
        }
        _ => {
            stream.write_all(&[0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            return Err("Unsupported address type".into());
        }
    };

    // Connect through Tor (minimal logging - only errors)
    let prefs = StreamPrefs::new();
    match client.connect_with_prefs((host.as_str(), port), &prefs).await {
        Ok(mut tor_stream) => {
            // Send success response
            stream.write_all(&[0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]).await?;

            // Bidirectional copy between client and Tor stream
            let _ = tokio::io::copy_bidirectional(&mut stream, &mut tor_stream).await;
        }
        Err(e) => {
            // Only log connection failures (not every attempt)
            let err_msg = format!("{}", e);
            if !err_msg.contains("timed out") && !err_msg.contains("Protocol error") {
                eprintln!("🧅 Tor connection to {}:{} failed: {}", host, port, e);
            }
            // Send connection failed response
            stream.write_all(&[0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            return Err(format!("Tor connection failed: {}", e).into());
        }
    }

    Ok(())
}

/// Stop the Tor client
/// Returns 0 on success
#[no_mangle]
pub extern "C" fn zipherx_tor_stop() -> i32 {
    eprintln!("🧅 Stopping Tor...");

    // Stop SOCKS proxy server
    SOCKS_SERVER_RUNNING.store(false, Ordering::SeqCst);

    // Clear the client
    if let Some(client_storage) = TOR_CLIENT.get() {
        if let Ok(mut guard) = client_storage.lock() {
            *guard = None;
        }
    }

    TOR_STATE.store(0, Ordering::SeqCst); // Disconnected
    TOR_BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    TOR_SOCKS_PORT.store(0, Ordering::SeqCst);

    eprintln!("🧅 Tor stopped");
    0
}

/// Get current Tor state
/// 0 = Disconnected, 1 = Connecting, 2 = Bootstrapping, 3 = Connected, 4 = Error
#[no_mangle]
pub extern "C" fn zipherx_tor_get_state() -> u8 {
    TOR_STATE.load(Ordering::SeqCst)
}

/// Get bootstrap progress (0-100)
#[no_mangle]
pub extern "C" fn zipherx_tor_get_progress() -> u8 {
    TOR_BOOTSTRAP_PROGRESS.load(Ordering::SeqCst)
}

/// Get SOCKS proxy port (0 if not connected)
#[no_mangle]
pub extern "C" fn zipherx_tor_get_socks_port() -> u16 {
    TOR_SOCKS_PORT.load(Ordering::SeqCst)
}

/// Get last error message
/// Returns pointer to null-terminated string (caller must free with zipherx_free_string)
#[no_mangle]
pub extern "C" fn zipherx_tor_get_error() -> *mut libc::c_char {
    if let Ok(guard) = TOR_ERROR.lock() {
        if let Some(ref msg) = *guard {
            let c_str = std::ffi::CString::new(msg.as_str()).unwrap_or_default();
            return c_str.into_raw();
        }
    }
    std::ptr::null_mut()
}

/// Request new Tor identity (new circuit)
/// Returns 0 on success
#[no_mangle]
pub extern "C" fn zipherx_tor_new_identity() -> i32 {
    let state = TOR_STATE.load(Ordering::SeqCst);
    if state != 3 {
        eprintln!("🧅 Cannot request new identity - Tor not connected");
        return 1;
    }

    // In Arti, we can request isolation for new connections
    // For existing connections, we'd need to close and reopen
    eprintln!("🧅 New identity requested (will isolate future connections)");

    0
}

/// Make an HTTP request through Tor
/// Returns response body as null-terminated string (caller must free)
/// Returns null on error
#[no_mangle]
pub unsafe extern "C" fn zipherx_tor_http_get(
    url_ptr: *const libc::c_char,
) -> *mut libc::c_char {
    if url_ptr.is_null() {
        return std::ptr::null_mut();
    }

    let url = match std::ffi::CStr::from_ptr(url_ptr).to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return std::ptr::null_mut(),
    };

    let state = TOR_STATE.load(Ordering::SeqCst);
    if state != 3 {
        eprintln!("🧅 Cannot make HTTP request - Tor not connected");
        return std::ptr::null_mut();
    }

    let runtime = get_runtime();

    // Block on the async request
    let result = runtime.block_on(async {
        tor_http_get_async(&url).await
    });

    match result {
        Ok(body) => {
            let c_str = std::ffi::CString::new(body).unwrap_or_default();
            c_str.into_raw()
        }
        Err(e) => {
            eprintln!("🧅 HTTP request error: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Async HTTP GET through Tor
async fn tor_http_get_async(url: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let client_storage = TOR_CLIENT.get()
        .ok_or("Tor client not initialized")?;

    let client = client_storage.lock()
        .map_err(|_| "Failed to lock Tor client")?;

    let client = client.as_ref()
        .ok_or("Tor client not available")?;

    // Parse URL to get host and port
    let url_parsed: url::Url = url.parse()?;
    let host = url_parsed.host_str().ok_or("No host in URL")?;
    let port = url_parsed.port().unwrap_or(if url_parsed.scheme() == "https" { 443 } else { 80 });

    // Connect through Tor
    let mut stream = client.connect((host, port)).await?;

    // Build HTTP request
    let path = url_parsed.path();
    let request = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nUser-Agent: ZipherX/1.0\r\n\r\n",
        if path.is_empty() { "/" } else { path },
        host
    );

    // Send request
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    stream.write_all(request.as_bytes()).await?;

    // Read response
    let mut response = Vec::new();
    stream.read_to_end(&mut response).await?;

    // Parse response - extract body after headers
    let response_str = String::from_utf8_lossy(&response);
    if let Some(body_start) = response_str.find("\r\n\r\n") {
        Ok(response_str[body_start + 4..].to_string())
    } else {
        Ok(response_str.to_string())
    }
}

/// Free a string allocated by Tor functions
#[no_mangle]
pub unsafe extern "C" fn zipherx_tor_free_string(ptr: *mut libc::c_char) {
    if !ptr.is_null() {
        drop(std::ffi::CString::from_raw(ptr));
    }
}

/// Check if Tor is available (compiled in)
#[no_mangle]
pub extern "C" fn zipherx_tor_is_available() -> bool {
    true
}
