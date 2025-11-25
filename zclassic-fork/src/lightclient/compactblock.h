// Copyright (c) 2025 ZipherX Development Team
// CompactBlock builder for ZIP-307 implementation

#ifndef BITCOIN_LIGHTCLIENT_COMPACTBLOCK_H
#define BITCOIN_LIGHTCLIENT_COMPACTBLOCK_H

#include "lightclient/compact_formats.pb.h"
#include "primitives/block.h"
#include "primitives/transaction.h"
#include "uint256.h"

namespace lightclient {

/**
 * Convert a full block to a compact block (ZIP-307 format)
 *
 * @param block The full block to convert
 * @param height The block height
 * @return CompactBlock containing only nullifiers, CMUs, and minimal ciphertext
 */
cash::z::wallet::sdk::rpc::CompactBlock BlockToCompactBlock(const CBlock& block, int height);

/**
 * Convert a transaction to a compact transaction
 *
 * @param tx The transaction to convert
 * @param txIndex The transaction index within the block
 * @return CompactTx containing spends and outputs
 */
cash::z::wallet::sdk::rpc::CompactTx TxToCompactTx(const CTransaction& tx, uint64_t txIndex);

} // namespace lightclient

#endif // BITCOIN_LIGHTCLIENT_COMPACTBLOCK_H
