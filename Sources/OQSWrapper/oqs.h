// Shim header: include system liboqs header
#pragma once
#include <oqs/oqs.h>

// liboqs 0.15 removed the Dilithium aliases in favor of ML-DSA names.
// Keep the old identifier available so Swift code compiles on both 0.14 and 0.15.
#if !defined(OQS_SIG_alg_dilithium_2) && defined(OQS_SIG_alg_ml_dsa_65)
#define OQS_SIG_alg_dilithium_2 OQS_SIG_alg_ml_dsa_65
#endif
