//! mayo2-sign <seedhex24> <messagefile> — a MAYO-2 keypair derived from the seed (pq-mayo 0.2.3, the
//! implementation the bank's Motoko verifier is proved against) and a signature over the file's
//! exact bytes, as JSON: publicKeyHex (4,912 bytes), signatureHex (186 bytes), messageBytes.
use pq_mayo::{KeyPair, Mayo2};
use rand::{rngs::StdRng, SeedableRng};
use serde_json::json;
use signature::Verifier;

fn main() {
    let seed_hex = std::env::args().nth(1).expect("seed hex (24 bytes)");
    let path = std::env::args().nth(2).expect("message file");
    let seed_vec = hex::decode(seed_hex).expect("seed hex");
    let seed: [u8; 24] = seed_vec.as_slice().try_into().expect("seed is 24 bytes");
    let keypair = KeyPair::<Mayo2>::from_seed(&seed).expect("mayo2 keypair");
    let msg = std::fs::read(path).expect("message file");
    let rng_seed: [u8; 32] = core::array::from_fn(|i| seed[i % 24].wrapping_add(i as u8));
    let mut rng = StdRng::from_seed(rng_seed);
    let sig = keypair.signing_key().sign_with_rng(&mut rng, &msg).expect("mayo2 sign");
    keypair.verifying_key().verify(&msg, &sig).expect("mayo2 verify");
    println!("{}", json!({
        "publicKeyHex": hex::encode(keypair.verifying_key().as_ref()),
        "signatureHex": hex::encode(sig.as_ref()),
        "messageBytes": msg.len()
    }));
}
