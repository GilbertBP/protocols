/**
 *Submitted for verification at Etherscan.io on 2020-03-30
 */

 pragma solidity ^0.7.0;


 /**
  * @title Singleton Factory (EIP-2470)
   * @notice Exposes CREATE2 (EIP-1014) to deploy bytecode on deterministic addresses based on initialization code and salt.
        * @author Ricardo Guilherme Schmidt (Status Research & Development GmbH)
    */
    contract Create2Factory {
        /**
         * @notice Deploys `_initCode` using `_salt` for defining the deterministic address.
         * @param _initCode Initialization code.
         * @param _salt Arbitrary value to modify resulting address.
         * @return createdContract Created contract address.
         */
        function deploy(bytes memory _initCode, bytes32 _salt)
            public
            returns (address payable createdContract)
        {
                assembly {
                            createdContract := create2(0, add(_initCode, 0x20), mload(_initCode), _salt)
                        }
                    require(createdContract != address(0), "CREATE2_FAILED");
            }
    }
    // IV is a value changed to generate the vanity address.
    // IV: 6583047
