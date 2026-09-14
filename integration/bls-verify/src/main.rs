//! thebes-bls-verify — verify a BLS12-381 certificate signature.
//!
//! Usage: thebes-bls-verify <signature-hex> <message-hex> <public-key-hex>
//! Prints BLS_OK and exits 0 when the signature verifies; BLS_FAIL and exits 1
//! otherwise. The message is the domain-separated bytes the network signs
//! ("\x0dic-state-root" followed by the certificate tree's root hash); the
//! caller assembles it. Verification is delegated to the
//! `ic-verify-bls-signature` crate, an implementation independent of anything
//! in this repository.

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: thebes-bls-verify <signature-hex> <message-hex> <public-key-hex>");
        std::process::exit(2);
    }
    let decode = |s: &str, what: &str| -> Vec<u8> {
        hex::decode(s).unwrap_or_else(|e| {
            eprintln!("{what}: invalid hex: {e}");
            std::process::exit(2);
        })
    };
    let sig = decode(&args[1], "signature");
    let msg = decode(&args[2], "message");
    let pk = decode(&args[3], "public key");
    match ic_verify_bls_signature::verify_bls_signature(&sig, &msg, &pk) {
        Ok(()) => println!("BLS_OK"),
        Err(_) => {
            println!("BLS_FAIL");
            std::process::exit(1);
        }
    }
}
