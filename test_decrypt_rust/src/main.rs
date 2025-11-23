use hex;
use blake2b_simd;
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce, aead::{Aead, KeyInit}};

fn main() {
    println!("Testing Sapling note decryption...\n");

    // IVK from our derivation - librustzcash_crh_ivk outputs in little-endian
    // So the display format IS the wire format for IVK
    let ivk_bytes: [u8; 32] = [
        0x6a, 0xc0, 0x6a, 0x14, 0x03, 0x44, 0x4a, 0xb3, 0x85, 0x54, 0x21, 0xfe, 0x18, 0x1a, 0x58, 0x6b,
        0xac, 0x7e, 0xe6, 0x59, 0x46, 0xf6, 0xf3, 0x94, 0xbb, 0x2b, 0x49, 0xac, 0x4b, 0xbc, 0x37, 0x05
    ];

    // EPK from tx 9724d0dd output 0 - reverse from display format
    let epk_display = "6d5e0c6a88089501c60acf7fed72bcb335c06aae0ee523f94379b782417bab4d";
    let epk_bytes: [u8; 32] = {
        let mut bytes = [0u8; 32];
        let decoded = hex::decode(epk_display).unwrap();
        // Reverse for wire format
        for i in 0..32 {
            bytes[i] = decoded[31 - i];
        }
        bytes
    };

    // ENC ciphertext - this is NOT reversed (it's raw bytes, not a uint256)
    let enc_hex = "428473d8eee0405116d5c026ee1321ff20b8157af28a61b3db19acf96785fa2f8601cb58ed323c7c07809a38485fe2a9d0d4c68789e049fc4d650532e500e4426d70806404df36c31263ed7c1d4e94522ea9e38cc2d9fa995d352c369440aff219794870b1a4ff4b0cc34899baa1c8a1f88ea2982afeb853f055564799a9d93bebb8a66470593b39d7c4ee047b1796f031b9a7f086053d7aa6bc93fef4b85e35c4ac7ef547254609c095033291ed01527b88f1018643120621b03d53b92bafa86f1cf1112e924863d7dadf4c3523346b0107f9ee9c45ed65ff6f490f1d29e21da8636a5e4fa6a6f77e885a00b68477e7161cd731d88bae0cf79385a489103b064e1a9680d1027c3c4e5f09c57288a6b5f332f586815620afc604bf9684debdb8a04ab6cf49923d28725d9227645a4bbc58671d95ebc9dc378a5ff8d6bdb1b791b9b6788ad114775aced685f93657a7f875798623aa37dc1d95602558bba92d2455124ce38354d125044884da4bc1f10ff05d1f4bc43065ceb1d8b911b4bcf90fe2a7c5e745bc1f33ec4fc1ed8cd935b25d0396d50ba22747b3dcc9d4371da41c0290e3710c27f8944e52d3c733bb643a4106a11596a78744f137979be026a33692e21bcd593f0ff2a01c008495948f059dd7b2521ac39b33bd07ea5df51d32c1b2b28ecbbad6c8872426490421998f99316d72504296499c9adaa1655a16cd7b8a320a9fc977ee914aa98929d645cc37b6b3bb19c6a88fd195dd576905f08ddbf8903294be945eef924e4d13d1e5d019653cee50c816d8eab605943d607ae07af62378bd";
    let enc_bytes: [u8; 580] = {
        let decoded = hex::decode(enc_hex).unwrap();
        let mut bytes = [0u8; 580];
        bytes.copy_from_slice(&decoded);
        bytes
    };

    println!("IVK (wire format): {}", hex::encode(&ivk_bytes));
    println!("EPK (wire format): {}", hex::encode(&epk_bytes));

    // Compute shared secret manually
    use jubjub::{ExtendedPoint, Fr};
    use group::{GroupEncoding, Curve, cofactor::CofactorGroup};
    use group::ff::PrimeField;

    // Parse EPK as point
    let epk_option = ExtendedPoint::from_bytes(&epk_bytes);
    if epk_option.is_none().into() {
        println!("\n❌ EPK is not a valid point!");
        return;
    }
    let epk_point = epk_option.unwrap();

    // Parse IVK as scalar
    let ivk_option = Fr::from_repr(ivk_bytes);
    if ivk_option.is_none().into() {
        println!("\n❌ IVK is not a valid scalar!");
        return;
    }
    let ivk_scalar = ivk_option.unwrap();

    // Compute shared secret: [8*ivk] * epk
    // Cofactor is 8, so we multiply epk by 8 first, then by ivk
    let epk_cleared = epk_point.clear_cofactor();
    let ka = ExtendedPoint::from(epk_cleared) * ivk_scalar;
    let ka_affine = ka.to_affine();
    let shared_secret = ka_affine.to_bytes();

    println!("\nShared secret: {}", hex::encode(&shared_secret));

    // KDF
    let mut kdf_input = [0u8; 64];
    kdf_input[..32].copy_from_slice(&shared_secret);
    kdf_input[32..].copy_from_slice(&epk_bytes);

    let kdf_key = blake2b_simd::Params::new()
        .hash_length(32)
        .personal(b"Zcash_SaplingKDF")
        .to_state()
        .update(&kdf_input)
        .finalize();

    println!("KDF key: {}", hex::encode(kdf_key.as_bytes()));

    // Try decryption
    let cipher_key = Key::from_slice(kdf_key.as_bytes());
    let cipher = ChaCha20Poly1305::new(cipher_key);
    let nonce = Nonce::from_slice(&[0u8; 12]);

    match cipher.decrypt(nonce, &enc_bytes[..]) {
        Ok(plaintext) => {
            println!("\n✅ Decryption SUCCESS!");
            println!("Plaintext length: {} bytes", plaintext.len());
            if plaintext.len() >= 20 {
                println!("Lead byte: 0x{:02x}", plaintext[0]);
                let value = u64::from_le_bytes(plaintext[12..20].try_into().unwrap());
                println!("Value: {} zatoshi ({:.8} ZCL)", value, value as f64 / 100_000_000.0);
            }
        }
        Err(e) => {
            println!("\n❌ Decryption FAILED: {:?}", e);

            // Try raw decryption
            use chacha20::ChaCha20;
            use chacha20::cipher::{KeyIvInit, StreamCipher};

            let mut raw_cipher = ChaCha20::new(cipher_key.into(), &[0u8; 12].into());
            let mut raw_plaintext = enc_bytes[..564].to_vec();
            raw_cipher.apply_keystream(&mut raw_plaintext);

            println!("\nRaw decrypted first 20 bytes: {}", hex::encode(&raw_plaintext[..20]));
            println!("Raw lead byte: 0x{:02x}", raw_plaintext[0]);

            if raw_plaintext[0] == 0x01 || raw_plaintext[0] == 0x02 {
                println!("Lead byte is VALID!");
            } else {
                println!("Lead byte is NOT valid (expected 0x01 or 0x02)");
            }
        }
    }
}
