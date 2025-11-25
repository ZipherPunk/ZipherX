// Copyright (c) 2025 ZipherX Development Team
// CompactBlock builder for ZIP-307 implementation

#include "lightclient/compactblock.h"
#include "lightclient/compact_formats.pb.h"
#include "primitives/block.h"
#include "primitives/transaction.h"
#include "uint256.h"
#include "util.h"

using namespace cash::z::wallet::sdk::rpc;

namespace lightclient {

CompactBlock BlockToCompactBlock(const CBlock& block, int height)
{
    CompactBlock compactBlock;

    // Set block ID
    BlockID* blockId = compactBlock.mutable_id();
    blockId->set_blockheight(height);

    uint256 blockHash = block.GetHash();
    blockId->set_blockhash(blockHash.begin(), 32);

    LogPrint("lightclient", "Converting block %d (%s) to compact format\n",
             height, blockHash.ToString());

    // Convert each transaction
    for (size_t txIndex = 0; txIndex < block.vtx.size(); txIndex++) {
        const CTransaction& tx = block.vtx[txIndex];

        // Skip transactions with no Sapling data
        if (tx.vShieldedSpend.empty() && tx.vShieldedOutput.empty()) {
            continue;
        }

        CompactTx* compactTx = compactBlock.add_vtx();
        *compactTx = TxToCompactTx(tx, txIndex);
    }

    LogPrint("lightclient", "Compact block contains %d transactions with Sapling data\n",
             compactBlock.vtx_size());

    return compactBlock;
}

CompactTx TxToCompactTx(const CTransaction& tx, uint64_t txIndex)
{
    CompactTx compactTx;

    compactTx.set_txindex(txIndex);

    uint256 txHash = tx.GetHash();
    compactTx.set_txhash(txHash.begin(), 32);

    // Add compact spends (just nullifiers)
    for (const auto& spend : tx.vShieldedSpend) {
        CompactSpend* compactSpend = compactTx.add_spends();
        compactSpend->set_nf(spend.nullifier.begin(), 32);
    }

    // Add compact outputs (cmu + epk + first 52 bytes of ciphertext)
    for (const auto& output : tx.vShieldedOutput) {
        CompactOutput* compactOutput = compactTx.add_outputs();

        // Set CMU (note commitment)
        compactOutput->set_cmu(output.cmu.begin(), 32);

        // Set ephemeral public key
        compactOutput->set_epk(output.ephemeralKey.begin(), 32);

        // Set first 52 bytes of ciphertext (contains note opening data)
        // The full ciphertext is 580 bytes, but we only need the first 52
        // for trial decryption (contains diversifier, value, rcm)
        if (output.ciphertext.size() >= 52) {
            compactOutput->set_ciphertext(output.ciphertext.begin(), 52);
        } else {
            LogPrint("lightclient", "Warning: ciphertext smaller than expected (%d bytes)\n",
                     output.ciphertext.size());
            compactOutput->set_ciphertext(output.ciphertext.begin(),
                                         output.ciphertext.size());
        }
    }

    LogPrint("lightclient", "Compact tx %s: %d spends, %d outputs\n",
             txHash.ToString(), compactTx.spends_size(), compactTx.outputs_size());

    return compactTx;
}

} // namespace lightclient
