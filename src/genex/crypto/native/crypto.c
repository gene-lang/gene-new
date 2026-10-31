/* OpenSSL owns the cryptography. This adapter imports only public RSA
 * components and pins RSASSA-PKCS1-v1_5 with SHA-256 (JOSE RS256). */
#include <stddef.h>
#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/evp.h>
#include <openssl/param_build.h>
#include <openssl/rsa.h>

int gene_crypto_verify_rs256(const unsigned char *modulus, size_t modulus_size,
                            const unsigned char *exponent, size_t exponent_size,
                            const unsigned char *message, size_t message_size,
                            const unsigned char *signature, size_t signature_size) {
    int valid = 0;
    BIGNUM *n = NULL, *e = NULL;
    OSSL_PARAM_BLD *builder = NULL;
    OSSL_PARAM *params = NULL;
    EVP_PKEY_CTX *import = NULL, *verify = NULL;
    EVP_PKEY *key = NULL;
    EVP_MD_CTX *digest = NULL;
    if (!modulus || !exponent || !signature || (!message && message_size) ||
        modulus_size < 256 || modulus_size > 1024 || exponent_size < 1 ||
        exponent_size > 8 || signature_size != modulus_size ||
        message_size > 1048576 || modulus[0] == 0 || exponent[0] == 0)
        return 0;
    n = BN_bin2bn(modulus, (int)modulus_size, NULL);
    e = BN_bin2bn(exponent, (int)exponent_size, NULL);
    if (!n || !e || BN_num_bits(n) < 2048 || !BN_is_odd(n) ||
        !BN_is_odd(e) || BN_is_one(e))
        goto done;
    builder = OSSL_PARAM_BLD_new();
    if (!builder || !OSSL_PARAM_BLD_push_BN(builder, OSSL_PKEY_PARAM_RSA_N, n) ||
        !OSSL_PARAM_BLD_push_BN(builder, OSSL_PKEY_PARAM_RSA_E, e))
        goto done;
    params = OSSL_PARAM_BLD_to_param(builder);
    import = EVP_PKEY_CTX_new_from_name(NULL, "RSA", NULL);
    if (!params || !import || EVP_PKEY_fromdata_init(import) <= 0 ||
        EVP_PKEY_fromdata(import, &key, EVP_PKEY_PUBLIC_KEY, params) <= 0)
        goto done;
    digest = EVP_MD_CTX_new();
    if (!digest || EVP_DigestVerifyInit_ex(digest, &verify, "SHA256", NULL,
                                         NULL, key, NULL) <= 0 ||
        EVP_PKEY_CTX_set_rsa_padding(verify, RSA_PKCS1_PADDING) <= 0)
        goto done;
    valid = EVP_DigestVerify(digest, signature, signature_size,
                            message, message_size) == 1;
done:
    EVP_MD_CTX_free(digest);
    EVP_PKEY_free(key);
    EVP_PKEY_CTX_free(import);
    OSSL_PARAM_free(params);
    OSSL_PARAM_BLD_free(builder);
    BN_free(n);
    BN_free(e);
    return valid;
}
