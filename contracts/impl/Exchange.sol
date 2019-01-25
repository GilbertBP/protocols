/*

  Copyright 2017 Loopring Project Ltd (Loopring Foundation).

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/
pragma solidity 0.5.2;

import "../iface/IExchange.sol";
import "../iface/ITradeDelegate.sol";

import "../lib/ERC20SafeTransfer.sol";
import "../lib/Verifier.sol";

import "../lib/BytesUtil.sol";
import "../lib/MathUint.sol";
import "../lib/NoDefaultFunc.sol";


/// @title An Implementation of IExchange.
/// @author Brecht Devos - <brecht@loopring.org>,
contract Exchange is IExchange, NoDefaultFunc {
    using MathUint          for uint;
    using BytesUtil         for bytes;
    using ERC20SafeTransfer for address;

    uint public MAX_NUM_DEPOSITS_IN_BLOCK       = 32;

    address public  tradeDelegateAddress        = address(0x0);

    event TokenRegistered(address tokenAddress, uint16 tokenID);
    event Deposit(uint24 account, uint16 dexID, address owner, address tokenAddress, uint amount);
    event Withdraw(uint24 account, uint16 dexID, address owner, address tokenAddress, uint amount);

    enum BlockState {
        COMMITTED,
        VERIFIED,
        FINALIZED
    }

    struct Token {
        address tokenAddress;
    }

    struct Account {
        address owner;
        uint16 dexID;
        address token;
    }

    struct DepositBlock {
        uint numDeposits;
        bytes32 hash;
        bool done;
    }

    struct Block {
        bytes32 accountsMerkleRoot;
        bytes32 tradeHistoryMerkleRoot;

        bytes withdrawals;

        BlockState state;
    }

    Token[] public tokens;
    mapping (address => uint16) public tokenToTokenID;

    Account[] public accounts;

    Block[] public blocks;

    mapping (uint => DepositBlock) public depositBlocks;

    uint256[14] vk;
    uint256[] gammaABC;

    constructor(
        address _tradeDelegateAddress
        )
        public
    {
        require(_tradeDelegateAddress != address(0x0), ZERO_ADDRESS);
        tradeDelegateAddress = _tradeDelegateAddress;

        Block memory genesisBlock = Block(
            0x282B2D2BEB6A5269A0162C8477825D3D9352526705DFA351483C72E68EAFE9A9,
            0x056E110222A84609DE5696E61A9F18731AFD9C4743F77D85C6F7267CB1617571,
            new bytes(0),
            BlockState.FINALIZED
        );
        blocks.push(genesisBlock);
    }

    function submitRings(
        bytes memory data,
        uint256[8] memory proof
        )
        public
    {
        Block storage currentBlock = blocks[blocks.length - 1];

        // TODO: don't send tradeHistoryMerkleRootBefore to save on calldata
        bytes32 accountsMerkleRootBefore;
        bytes32 accountsMerkleRootAfter;
        bytes32 tradeHistoryMerkleRootBefore;
        bytes32 tradeHistoryMerkleRootAfter;
        assembly {
            accountsMerkleRootBefore := mload(add(data, 32))
            accountsMerkleRootAfter := mload(add(data, 64))
            tradeHistoryMerkleRootBefore := mload(add(data, 96))
            tradeHistoryMerkleRootAfter := mload(add(data, 128))
        }
        require(accountsMerkleRootBefore == currentBlock.accountsMerkleRoot, "INVALID_ACCOUNTS_ROOT");
        require(tradeHistoryMerkleRootBefore == currentBlock.tradeHistoryMerkleRoot, "INVALID_TRADEHISTORY_ROOT");

        bytes32 publicDataHash = sha256(data);
        bool verified = verifyProof(publicDataHash, proof);
        require(verified, "INVALID_PROOF");

        // Create a new block with the updated merkle roots
        Block memory newBlock = Block(
            accountsMerkleRootAfter,
            tradeHistoryMerkleRootAfter,
            new bytes(0),
            BlockState.FINALIZED
        );
        blocks.push(newBlock);
    }

    function submitDeposits(
        bytes memory data,
        uint256[8] memory proof
        )
        public
    {
        Block storage currentBlock = blocks[blocks.length - 1];

        // TODO: don't send accountsMerkleRootBefore to save on calldata
        bytes32 accountsMerkleRootBefore;
        bytes32 accountsMerkleRootAfter;
        assembly {
            accountsMerkleRootBefore := mload(add(data, 32))
            accountsMerkleRootAfter := mload(add(data, 64))
        }
        require(accountsMerkleRootBefore == currentBlock.accountsMerkleRoot, "INVALID_ACCOUNTS_ROOT");

        bytes32 publicDataHash = sha256(data);
        bool verified = verifyProof(publicDataHash, proof);
        require(verified, "INVALID_PROOF");

        // Create a new block with the updated merkle roots
        Block memory newBlock = Block(
            accountsMerkleRootAfter,
            currentBlock.tradeHistoryMerkleRoot,
            new bytes(0),
            BlockState.FINALIZED
        );
        blocks.push(newBlock);
    }

    function submitWithdrawals(
        bytes memory data,
        uint256[8] memory proof
        )
        public
    {
        Block storage currentBlock = blocks[blocks.length - 1];

        // TODO: don't send accountsMerkleRootBefore to save on calldata
        bytes32 accountsMerkleRootBefore;
        bytes32 accountsMerkleRootAfter;
        assembly {
            accountsMerkleRootBefore := mload(add(data, 32))
            accountsMerkleRootAfter := mload(add(data, 64))
        }
        require(accountsMerkleRootBefore == currentBlock.accountsMerkleRoot, "INVALID_ACCOUNTS_ROOT");

        bytes32 publicDataHash = sha256(data);
        bool verified = verifyProof(publicDataHash, proof);
        require(verified, "INVALID_PROOF");

        // Create a new block with the updated merkle roots
        Block memory newBlock = Block(
            accountsMerkleRootAfter,
            currentBlock.tradeHistoryMerkleRoot,
            data,
            BlockState.FINALIZED
        );
        blocks.push(newBlock);
    }

    function registerToken(
        address tokenAddress
        )
        external
    {
        require(tokenToTokenID[tokenAddress] == 0, "ALREADY_REGISTERED");
        Token memory token = Token(
            tokenAddress
        );
        tokens.push(token);

        tokenToTokenID[tokenAddress] = uint16(tokens.length);

        emit TokenRegistered(tokenAddress, uint16(tokens.length) - 1);
    }

    function getTokenID(
        address tokenAddress
        )
        public
        view
        returns (uint16)
    {
        require(tokenToTokenID[tokenAddress] != 0, "TOKEN_NOT_REGISTERED");
        return tokenToTokenID[tokenAddress] - 1;
    }

    function deposit(
        address owner,
        uint brokerPublicKeyX,
        uint brokerPublicKeyY,
        uint16 dexID,
        address token,
        uint amount
        )
        public
        returns (uint24)
    {
        require(msg.sender == owner, "UNAUTHORIZED");
        uint16 tokenID = getTokenID(token);

        uint currentBlock = block.number / 40;
        DepositBlock storage depositBlock = depositBlocks[currentBlock];
        require(depositBlock.numDeposits < MAX_NUM_DEPOSITS_IN_BLOCK, "DEPOSIT_BLOCK_FULL");
        if (depositBlock.numDeposits == 0) {
            depositBlock.hash = bytes32(accounts.length);
        }

        if (amount > 0) {
            // Transfer the tokens from the owner into this contract
            require(
                token.safeTransferFrom(
                    owner,
                    address(this),
                    amount
                ),
                "UNSUFFICIENT_FUNDS"
            );
        }

        depositBlock.hash = sha256(
            abi.encodePacked(
                depositBlock.hash,
                brokerPublicKeyX,
                brokerPublicKeyY,
                dexID,
                tokenID,
                amount
            )
        );
        depositBlock.numDeposits++;

        Account memory account = Account(
            owner,
            dexID,
            token
        );
        uint24 accountID = uint24(accounts.length);
        accounts.push(account);

        emit Deposit(accountID, dexID, owner, token, amount);

        return accountID;
    }

    function withdraw(
        uint16 dexID,
        uint blockIdx,
        uint withdrawalIdx
        )
        external
    {
        Block storage withdrawBlock = blocks[blockIdx];
        require(withdrawBlock.state == BlockState.FINALIZED, "BLOCK_NOT_FINALIZED");

        // TODO: optimize
        bytes memory withdrawals = withdrawBlock.withdrawals;
        uint offset = 32 + 32 + (3 + 12) * (withdrawalIdx + 1);
        uint data;
        assembly {
            data := mload(add(withdrawals, offset))
        }
        uint24 accountID = uint24((data / 0x1000000000000000000000000) & 0xFFFFFF);
        uint amount = data & 0xFFFFFFFFFFFFFFFFFFFFFFFF;

        if (amount > 0) {
            Account storage account = accounts[accountID];
            // Transfer the tokens from the contract to the owner
            require(
                account.token.safeTransfer(
                    account.owner,
                    amount
                ),
                TRANSFER_FAILURE
            );

            // Set the amount to 0 so it cannot be withdrawn anymore
            data = data & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF000000000000000000000000;
            assembly {
                mstore(add(withdrawals, offset), data)
            }
            withdrawBlock.withdrawals = withdrawals;

            emit Withdraw(accountID, dexID, account.owner, account.token, amount);
        }
    }

    function verifyProof(
        bytes32 _publicDataHash,
        uint256[8] memory proof
        )
        internal
        view
        returns (bool)
    {
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = uint256(_publicDataHash);

        uint256[14] memory _vk;
        uint256[] memory _vk_gammaABC;
        (_vk, _vk_gammaABC) = getVerifyingKey();

        return Verifier.Verify(_vk, _vk_gammaABC, proof, publicInputs);
    }

    function getVerifyingKey()
        public
        view
        returns (uint256[14] memory out_vk, uint256[] memory out_gammaABC)
    {
        return (vk, gammaABC);
    }

    function setVerifyingKey(
        uint256[14] memory _vk,
        uint256[] memory _gammaABC
        )
        public
    {
        vk = _vk;
        gammaABC = _gammaABC;
    }

    function getLastBlockIdx()
        external
        view
        returns (uint)
    {
        return blocks.length - 1;
    }
}
