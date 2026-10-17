// "none" attestations of freshly generated keys; the public keys are what
// Node's `KeyObject.export({format: 'der', type: 'spki'})` gives for the same
// key, base64url.

/// P-256, made by Google Password Manager (by its AAGUID).
const p256Attestation =
    'o2NmbXRkbm9uZWdhdHRTdG10oGhhdXRoRGF0YViUyLCtSM85oHOeFlh8S6snCHCk4IDROXhf'
    'rfLJswbkzENFAAAAAOqbjWZNAR0hPOS2tIy1ddQAEBYrATDlhUPr9WpM289TpDClAQIDJiAB'
    'IVgg1Bzs3swqzJYI11tzdiKHRBuuirSUw6hXxxa0uoy2R1ciWCCilQdpmRrYLccFFfnwF5DV'
    'BIxGb4HEn9QFTX0bPRhOxw';
const p256PublicKey =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE1Bzs3swqzJYI11tzdiKHRBuuirSUw6hXxxa0'
    'uoy2R1eilQdpmRrYLccFFfnwF5DVBIxGb4HEn9QFTX0bPRhOxw';

/// RSA-2048, from a provider with an all-zero AAGUID.
const rsaAttestation =
    'o2NmbXRkbm9uZWdhdHRTdG10oGhhdXRoRGF0YVkBV8iwrUjPOaBznhZYfEurJwhwpOCA0Tl4'
    'X63yybMG5MxDRQAAAAAAAAAAAAAAAAAAAAAAAAAAABDjqQqpLMHvQ8_N241s0207pAEDAzkB'
    'ACBZAQCAxzEWPO-SJBPeLmsRZuwfBhnict4d_0NPwMDS1XLI6GMSpgMOj74ZqEQiS2v3a2Mo'
    'HTjlTsf1EVPZ9uwE5W7lanbvJ67WvlEV61virxGw4EguCvJ2bpLN8ZSEw9HzE7xCDtoYpZuR'
    'iE8ywlvorWqnHmG8bgmh7aRfkfdSKHui3UMQrnkLyfDYNtqlcE8TUmXH8HzWyP9TxsDllkGz'
    '1h6-uFJB28bv73_1G7krlThTZuke1hDhYBzP44KkWnPQvtTcv4ofGEoyErqNZkimCvIluJtx'
    '1enooyKpMUqUyoc9wDGHjluCfXbtqXTBbuakiwLon4qCBka_nXG3gvLuqvwfIUMBAAE';
const rsaPublicKey =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAgMcxFjzvkiQT3i5rEWbsHwYZ4nLe'
    'Hf9DT8DA0tVyyOhjEqYDDo--GahEIktr92tjKB045U7H9RFT2fbsBOVu5Wp27yeu1r5RFetb'
    '4q8RsOBILgrydm6SzfGUhMPR8xO8Qg7aGKWbkYhPMsJb6K1qpx5hvG4Joe2kX5H3Uih7ot1D'
    'EK55C8nw2DbapXBPE1Jlx_B81sj_U8bA5ZZBs9YevrhSQdvG7-9_9Ru5K5U4U2bpHtYQ4WAc'
    'z-OCpFpz0L7U3L-KHxhKMhK6jWZIpgryJbibcdXp6KMiqTFKlMqHPcAxh45bgn127al0wW7m'
    'pIsC6J-KggZGv51xt4Ly7qr8HwIDAQAB';
