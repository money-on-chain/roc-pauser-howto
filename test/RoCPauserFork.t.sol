// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// This test deliberately has no forge-std or protocol package dependency.
interface Vm {
    function prank(address sender) external;
}

interface IPausable {
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function stoppable() external view returns (bool);
    function pause() external;
    function unpause() external;
}

interface IMultiCollateralGuard {
    function getBucketAmount() external view returns (uint256);
    function buckets(uint256 index) external view returns (address);
}

interface IBucket {
    function mocQueue() external view returns (address);
}

interface IMultiSendCallOnly {
    function multiSend(bytes calldata transactions) external payable;
}

enum Operation {
    Call,
    DelegateCall
}

interface ISafe {
    function VERSION() external view returns (string memory);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function approveHash(bytes32 hashToApprove) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 txNonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

contract RoCPauserForkTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ISafe private constant SAFE = ISafe(0x817aC952d616c1e2Fa5c6D6DD20b3D15f10dDb03);
    address private constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;

    address private constant GUARD = 0x0237Ad1f0831b479a344E56646BC48B0885cF46F;
    address private constant RIF_BUCKET = 0xA27024Ed70035E46dba712609fc2Afa1c97aA36A;
    address private constant DOC_BUCKET = 0x697535055Aa7AfD2C280523C7B062b1F05284661;
    address private constant RIF_QUEUE = 0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1;
    address private constant DOC_QUEUE = 0x2BBCBC2CD2F2655d5A4306637c46Bcf2E6D859f6;

    function testFiveContractPauseAndUnpauseThroughRealSafe() public {
        require(block.chainid == 30, "fork Rootstock mainnet (chain 30)");
        require(keccak256(bytes(SAFE.VERSION())) == keccak256("1.4.1"), "Safe version changed");
        require(MULTISEND_CALL_ONLY.code.length != 0, "MultiSendCallOnly is not deployed");

        // These checks prevent a stale address list from silently testing other contracts.
        require(IMultiCollateralGuard(GUARD).getBucketAmount() == 2, "bucket count changed");
        require(IMultiCollateralGuard(GUARD).buckets(0) == RIF_BUCKET, "RIF bucket changed");
        require(IMultiCollateralGuard(GUARD).buckets(1) == DOC_BUCKET, "DOC bucket changed");
        require(IBucket(RIF_BUCKET).mocQueue() == RIF_QUEUE, "RIF queue changed");
        require(IBucket(DOC_BUCKET).mocQueue() == DOC_QUEUE, "DOC queue changed");

        address[5] memory targets = _pauseOrder();
        for (uint256 i; i < targets.length; i++) {
            IPausable target = IPausable(targets[i]);
            require(target.pauser() == address(SAFE), "pauser changed");
            require(target.stoppable(), "target cannot be paused");
            require(!target.paused(), "target already paused");
        }

        address[] memory owners = SAFE.getOwners();
        uint256 threshold = SAFE.getThreshold();
        require(threshold == 4, "Safe threshold changed");
        require(owners.length >= 2 * threshold, "need two distinct owner groups");

        address[] memory pauseSigners = _selectAndSort(owners, 0, threshold);
        uint256 nonceBefore = SAFE.nonce();
        _executeSafeBatch(_pauseOrder(), IPausable.pause.selector, pauseSigners, true);
        require(SAFE.nonce() == nonceBefore + 1, "pause nonce did not advance");
        _assertAllPaused(true);

        // A different set of four actual owners approves and executes the resume.
        address[] memory unpauseSigners = _selectAndSort(owners, threshold, threshold);
        _executeSafeBatch(_unpauseOrder(), IPausable.unpause.selector, unpauseSigners, false);
        require(SAFE.nonce() == nonceBefore + 2, "unpause nonce did not advance");
        _assertAllPaused(false);
    }

    function _executeSafeBatch(address[5] memory targets, bytes4 action, address[] memory signers, bool proveThreshold)
        private
    {
        bytes memory data = abi.encodeCall(IMultiSendCallOnly.multiSend, (_packCalls(targets, action)));
        uint256 txNonce = SAFE.nonce();
        bytes32 txHash = SAFE.getTransactionHash(
            MULTISEND_CALL_ONLY, 0, data, Operation.DelegateCall, 0, 0, 0, address(0), address(0), txNonce
        );
        bytes memory signatures = _approvedHashSignatures(signers);

        // Impersonate each real owner on the fork; no private key is used.
        for (uint256 i; i < signers.length - 1; i++) {
            vm.prank(signers[i]);
            SAFE.approveHash(txHash);
        }

        if (proveThreshold) {
            // Three approvals are insufficient for this four-of-nine Safe.
            (bool accepted,) = address(SAFE)
                .call(
                    abi.encodeCall(
                        ISafe.execTransaction,
                        (
                            MULTISEND_CALL_ONLY,
                            0,
                            data,
                            Operation.DelegateCall,
                            0,
                            0,
                            0,
                            address(0),
                            payable(address(0)),
                            signatures
                        )
                    )
                );
            require(!accepted && SAFE.nonce() == txNonce, "Safe accepted fewer than four approvals");
        }

        vm.prank(signers[signers.length - 1]);
        SAFE.approveHash(txHash);

        bool success = SAFE.execTransaction(
            MULTISEND_CALL_ONLY, 0, data, Operation.DelegateCall, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        require(success, "Safe batch failed");
    }

    function _packCalls(address[5] memory targets, bytes4 action) private pure returns (bytes memory packed) {
        for (uint256 i; i < targets.length; i++) {
            // Safe MultiSend format: operation(1) | to(20) | value(32) | dataLength(32) | data.
            // Inner operations are CALL; the Safe DELEGATECALLs only into MultiSendCallOnly.
            packed = bytes.concat(
                packed, abi.encodePacked(uint8(Operation.Call), targets[i], uint256(0), uint256(4), action)
            );
        }
    }

    function _approvedHashSignatures(address[] memory sortedSigners) private pure returns (bytes memory signatures) {
        for (uint256 i; i < sortedSigners.length; i++) {
            // Safe approved-hash signature: r = owner, s = 0, v = 1. Signers must be sorted.
            signatures = bytes.concat(
                signatures, abi.encodePacked(bytes32(uint256(uint160(sortedSigners[i]))), bytes32(0), uint8(1))
            );
        }
    }

    function _selectAndSort(address[] memory owners, uint256 offset, uint256 count)
        private
        pure
        returns (address[] memory selected)
    {
        selected = new address[](count);
        for (uint256 i; i < count; i++) {
            selected[i] = owners[offset + i];
        }
        for (uint256 i = 1; i < count; i++) {
            address current = selected[i];
            uint256 j = i;
            while (j > 0 && uint160(selected[j - 1]) > uint160(current)) {
                selected[j] = selected[j - 1];
                j--;
            }
            selected[j] = current;
        }
    }

    function _assertAllPaused(bool expected) private view {
        address[5] memory targets = _pauseOrder();
        for (uint256 i; i < targets.length; i++) {
            require(IPausable(targets[i]).paused() == expected, "unexpected paused state");
        }
    }

    function _pauseOrder() private pure returns (address[5] memory targets) {
        return [GUARD, RIF_QUEUE, DOC_QUEUE, RIF_BUCKET, DOC_BUCKET];
    }

    function _unpauseOrder() private pure returns (address[5] memory targets) {
        return [RIF_BUCKET, DOC_BUCKET, RIF_QUEUE, DOC_QUEUE, GUARD];
    }
}
