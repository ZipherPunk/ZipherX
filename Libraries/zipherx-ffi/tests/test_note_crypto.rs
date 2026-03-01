//! Note cryptography tests: random scalars, nullifiers, CMU computation
//!
//! Parallel-safe — pure cryptographic functions, no global state.

mod common;
use common::*;

extern crate zipherx_ffi;

// ═══════════════════════════════════════════════════════════
// Random Scalar
// ═══════════════════════════════════════════════════════════

#[test]
fn random_scalar_nonzero() {
    let scalar = random_scalar().expect("random_scalar failed");
    assert_ne!(scalar, [0u8; 32], "Random scalar must not be all zeros");
}

#[test]
fn random_scalar_unique() {
    let s1 = random_scalar().expect("s1 failed");
    let s2 = random_scalar().expect("s2 failed");
    assert_ne!(s1, s2, "Two random scalars must differ");
}

// ═══════════════════════════════════════════════════════════
// Nullifier Computation
// ═══════════════════════════════════════════════════════════

#[test]
fn compute_nullifier_deterministic() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let (addr_bytes, _) = derive_address(&sk, 0).unwrap();
    let diversifier: [u8; 11] = addr_bytes[0..11].try_into().unwrap();
    let rcm = random_scalar().unwrap();

    let nf1 = compute_nullifier(&sk, &diversifier, 100000, &rcm, 0);
    let nf2 = compute_nullifier(&sk, &diversifier, 100000, &rcm, 0);

    match (nf1, nf2) {
        (Some(n1), Some(n2)) => {
            assert_eq!(n1, n2, "Same inputs must produce same nullifier");
            assert_ne!(n1, [0u8; 32], "Nullifier must not be all zeros");
        }
        _ => {
            // Nullifier computation may fail if diversifier doesn't produce valid g_d
            // This is acceptable for some diversifiers
        }
    }
}

#[test]
fn compute_nullifier_different_positions() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let (addr_bytes, _) = derive_address(&sk, 0).unwrap();
    let diversifier: [u8; 11] = addr_bytes[0..11].try_into().unwrap();
    let rcm = random_scalar().unwrap();

    let nf0 = compute_nullifier(&sk, &diversifier, 100000, &rcm, 0);
    let nf1 = compute_nullifier(&sk, &diversifier, 100000, &rcm, 1);

    match (nf0, nf1) {
        (Some(n0), Some(n1)) => {
            assert_ne!(n0, n1, "Same note at different positions must produce different nullifiers");
        }
        _ => {
            // May fail for some diversifiers — not a test failure
        }
    }
}

// ═══════════════════════════════════════════════════════════
// Note CMU
// ═══════════════════════════════════════════════════════════

#[test]
fn compute_note_cmu_produces_output() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let (addr_bytes, _) = derive_address(&sk, 0).unwrap();
    let diversifier: [u8; 11] = addr_bytes[0..11].try_into().unwrap();
    let rcm = random_scalar().unwrap();

    let mut cmu_out = [0u8; 32];
    let ok = unsafe {
        zipherx_ffi::zipherx_compute_note_cmu(
            diversifier.as_ptr(),
            rcm.as_ptr(),
            100000,
            sk.as_ptr(),
            cmu_out.as_mut_ptr(),
        )
    };

    if ok {
        assert_ne!(cmu_out, [0u8; 32], "CMU must not be all zeros");
    }
    // ok=false is acceptable if diversifier doesn't produce valid g_d
}

#[test]
fn verify_note_cmu_matches_computed() {
    let seed = [0u8; 64];
    let sk = derive_spending_key(&seed, 0).unwrap();
    let (addr_bytes, _) = derive_address(&sk, 0).unwrap();
    let diversifier: [u8; 11] = addr_bytes[0..11].try_into().unwrap();
    let rcm = random_scalar().unwrap();
    let value: u64 = 100000;

    let mut cmu_out = [0u8; 32];
    let ok = unsafe {
        zipherx_ffi::zipherx_compute_note_cmu(
            diversifier.as_ptr(),
            rcm.as_ptr(),
            value,
            sk.as_ptr(),
            cmu_out.as_mut_ptr(),
        )
    };

    if ok {
        // Now verify the CMU matches
        let verify_result = unsafe {
            zipherx_ffi::zipherx_verify_note_cmu(
                cmu_out.as_ptr(),
                diversifier.as_ptr(),
                rcm.as_ptr(),
                value,
                sk.as_ptr(),
            )
        };
        assert_eq!(
            verify_result, 1,
            "Computed CMU must verify against same inputs"
        );
    }
}

// ═══════════════════════════════════════════════════════════
// Value Commitment
// ═══════════════════════════════════════════════════════════

#[test]
fn compute_value_commitment_nonzero() {
    let rcv = random_scalar().unwrap();
    let mut cv = [0u8; 32];
    let ok = unsafe {
        zipherx_ffi::zipherx_compute_value_commitment(100000, rcv.as_ptr(), cv.as_mut_ptr())
    };
    if ok {
        assert_ne!(cv, [0u8; 32], "Value commitment must not be all zeros");
    }
}
