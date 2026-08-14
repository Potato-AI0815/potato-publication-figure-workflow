#!/usr/bin/env Rscript
# sha256.R — SHA-256 文件摘要（零额外依赖可运行; 有 digest/openssl 时自动加速）
# 用途: 审计新鲜度绑定（audited_artifacts sha256）与 AUDIT_STALE 判定。
# 提供:
#   sha256_raw(bytes)  integer 字节向量 (0..255) -> 64 位小写 hex
#   sha256_file(path)  文件 SHA-256（digest > openssl > 纯 R 回退）
# 纯 R 实现按 FIPS 180-4; 以 16-bit 半字表达 32-bit 字, 全部运算在 double 精确域内。

.sha256_K <- c(
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2)

.sha256_H0 <- c(0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19)

## 32-bit 运算（double 表示, [0, 2^32)）
.xor32 <- function(a, b) {
  bitwXor(as.integer(a %/% 65536), as.integer(b %/% 65536)) * 65536 +
    bitwXor(as.integer(a %% 65536), as.integer(b %% 65536))
}
.and32 <- function(a, b) {
  bitwAnd(as.integer(a %/% 65536), as.integer(b %/% 65536)) * 65536 +
    bitwAnd(as.integer(a %% 65536), as.integer(b %% 65536))
}
.not32 <- function(a) 4294967295 - a
.rotr32 <- function(x, n) (x %/% 2^n) + (x * 2^(32 - n)) %% 4294967296
.shr32 <- function(x, n) x %/% 2^n

sha256_raw <- function(bytes) {
  bytes <- as.integer(bytes)
  L <- length(bytes)
  bitlen <- L * 8
  padzeros <- (56 - (L + 1) %% 64 + 64) %% 64
  hi <- bitlen %/% 4294967296
  lo <- bitlen %% 4294967296
  len_bytes <- as.integer(c(hi %/% 16777216, (hi %/% 65536) %% 256,
                            (hi %/% 256) %% 256, hi %% 256,
                            lo %/% 16777216, (lo %/% 65536) %% 256,
                            (lo %/% 256) %% 256, lo %% 256))
  bytes <- c(bytes, 0x80L, rep(0L, padzeros), len_bytes)
  nb <- length(bytes) %/% 64
  m <- matrix(as.double(bytes), ncol = 64, byrow = TRUE)
  ## 每块前 16 个 32-bit 大端字（drop=FALSE: 单块输入不得降维为向量）
  W0 <- m[, seq(1, 61, 4), drop = FALSE] * 16777216 +
    m[, seq(2, 62, 4), drop = FALSE] * 65536 +
    m[, seq(3, 63, 4), drop = FALSE] * 256 + m[, seq(4, 64, 4), drop = FALSE]
  H <- .sha256_H0
  K <- .sha256_K
  for (b in seq_len(nb)) {
    w <- numeric(64)
    w[1:16] <- W0[b, ]
    for (t in 17:64) {
      s0 <- .xor32(.xor32(.rotr32(w[t - 15], 7), .rotr32(w[t - 15], 18)),
                   .shr32(w[t - 15], 3))
      s1 <- .xor32(.xor32(.rotr32(w[t - 2], 17), .rotr32(w[t - 2], 19)),
                   .shr32(w[t - 2], 10))
      w[t] <- (w[t - 16] + s0 + w[t - 7] + s1) %% 4294967296
    }
    a <- H[1]; bb <- H[2]; cc <- H[3]; d <- H[4]
    e <- H[5]; f <- H[6]; g <- H[7]; h <- H[8]
    for (t in 1:64) {
      S1 <- .xor32(.xor32(.rotr32(e, 6), .rotr32(e, 11)), .rotr32(e, 25))
      ch <- .xor32(.and32(e, f), .and32(.not32(e), g))
      t1 <- (h + S1 + ch + K[t] + w[t]) %% 4294967296
      S0 <- .xor32(.xor32(.rotr32(a, 2), .rotr32(a, 13)), .rotr32(a, 22))
      maj <- .xor32(.xor32(.and32(a, bb), .and32(a, cc)), .and32(bb, cc))
      t2 <- (S0 + maj) %% 4294967296
      h <- g; g <- f; f <- e; e <- (d + t1) %% 4294967296
      d <- cc; cc <- bb; bb <- a; a <- (t1 + t2) %% 4294967296
    }
    H <- (H + c(a, bb, cc, d, e, f, g, h)) %% 4294967296
  }
  paste(vapply(H, function(x) sprintf("%04x%04x", as.integer(x %/% 65536),
                                      as.integer(x %% 65536)), character(1)),
        collapse = "")
}

## 文件 SHA-256: digest > openssl > 纯 R（全部返回 64 位小写 hex）
sha256_file <- function(path) {
  if (!file.exists(path)) stop(sprintf("sha256_file: file not found: %s", path))
  if (requireNamespace("digest", quietly = TRUE)) {
    return(tolower(digest::digest(file = path, algo = "sha256")))
  }
  if (requireNamespace("openssl", quietly = TRUE)) {
    raw <- readBin(path, "raw", n = file.info(path)$size)
    return(as.character(openssl::sha256(raw)))
  }
  raw <- readBin(path, "raw", n = file.info(path)$size)
  sha256_raw(as.integer(raw))
}
