// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.6.11;

import "@summa-tx/memview-sol/contracts/TypedMemView.sol";
import "./Common.sol";
import "./Merkle.sol";
import "./Queue.sol";

abstract contract Replica is Common, QueueManager {
    using QueueLib for QueueLib.Queue;

    uint32 public immutable ownSLIP44;
    uint256 public optimisticSeconds;

    mapping(bytes32 => uint256) public confirmAt;

    constructor(
        uint32 _originSLIP44,
        uint32 _ownSLIP44,
        address _updater,
        uint256 _optimisticSeconds,
        bytes32 _current
    ) Common(_originSLIP44, _updater, _current) QueueManager() {
        ownSLIP44 = _ownSLIP44;
        optimisticSeconds = _optimisticSeconds;
        current = _current;
    }

    function fail() internal override {
        _setFailed();
    }

    /// Hook for tasks
    function _beforeConfirm() internal virtual;

    /// Hook for tasks
    function _beforeUpdate() internal virtual;

    function next_pending()
        external
        view
        returns (bytes32 _pending, uint256 _confirmAt)
    {
        if (queue.length() != 0) {
            _pending = queue.peek();
            _confirmAt = confirmAt[_pending];
        }
    }

    // TODO: refactor to queue
    function update(
        bytes32 _oldRoot,
        bytes32 _newRoot,
        bytes memory _signature
    ) external notFailed {
        if (queue.length() > 0) {
            require(_oldRoot == queue.lastItem(), "Not end of queue");
        } else {
            require(current == _oldRoot, "Not current update");
        }
        require(Common.checkSig(_newRoot, _oldRoot, _signature), "Bad sig");

        _beforeUpdate();

        confirmAt[_newRoot] = block.timestamp + optimisticSeconds;
        queue.enqueue(_newRoot);
    }

    function confirm() external notFailed {
        require(queue.length() != 0, "No pending");

        bytes32 _pending;
        uint256 _now = block.timestamp;
        while (_now >= confirmAt[queue.peek()]) {
            _pending = queue.dequeue();
            delete confirmAt[_pending];
        }

        // This condition is hit if the while loop is never executed, because
        // the first queue item has not hit its timer yet
        require(_pending != bytes32(0), "Not time");

        _beforeConfirm();

        current = _pending;
    }
}

contract ProcessingReplica is Replica {
    using MerkleLib for MerkleLib.Tree;
    using TypedMemView for bytes;
    using TypedMemView for bytes29;
    using Message for bytes29;

    // minimum gas for message processing
    uint256 public constant PROCESS_GAS = 500000;
    // reserved gas (to ensure tx completes in case message processing runs out)
    uint256 public constant RESERVE_GAS = 10000;

    bytes32 public previous; // to smooth over witness invalidation
    uint256 public lastProcessed;
    mapping(bytes32 => MessageStatus) public messages;
    enum MessageStatus {None, Pending, Processed}

    constructor(
        uint32 _originSLIP44,
        uint32 _ownSLIP44,
        address _updater,
        uint256 _optimisticSeconds,
        bytes32 _start,
        uint256 _lastProcessed
    ) Replica(_originSLIP44, _ownSLIP44, _updater, _optimisticSeconds, _start) {
        lastProcessed = _lastProcessed;
    }

    function _beforeConfirm() internal override {
        previous = current;
    }

    function _beforeUpdate() internal override {}

    function process(bytes memory _message)
        public
        returns (bool, bytes memory)
    {
        bytes29 _m = _message.ref(0);

        uint32 _sequence = _m.sequence();
        require(_m.destination() == ownSLIP44, "!destination");
        require(_sequence == lastProcessed + 1, "!sequence");
        require(
            messages[keccak256(_message)] == MessageStatus.Pending,
            "not pending"
        );
        lastProcessed = _sequence;
        messages[_m.keccak()] = MessageStatus.Processed;

        // TODO: assembly this to avoid the clone?
        bytes memory payload = _m.body().clone();
        address recipient = _m.recipientAddress();

        // NB:
        // A call running out of gas TYPICALLY errors the whole tx. We want to
        // a) ensure the call has a sufficient amount of gas to make a
        //    meaningful state change.
        // b) ensure that if the subcall runs out of gas, that the tx as a whole
        //    does not revert (i.e. we still mark the message processed)
        // To do this, we require that we have enough gas to process
        // and still return. We then delegate only the minimum processing gas.
        require(gasleft() >= PROCESS_GAS + RESERVE_GAS, "!gas");
        // transparently return.
        return recipient.call{gas: PROCESS_GAS}(payload);
    }

    function prove(
        bytes32 leaf,
        bytes32[32] calldata proof,
        uint256 index
    ) public returns (bool) {
        bytes32 actual = MerkleLib.branchRoot(leaf, proof, index);

        // NB:
        // For convenience, we allow proving against the previous root.
        // This means that witnesses don't need to be updated for the new root
        if (actual == current || actual == previous) {
            messages[leaf] = MessageStatus.Pending;
            return true;
        }
        return false;
    }

    function proveAndProcess(
        bytes32 leaf,
        bytes32[32] calldata proof,
        uint256 index,
        bytes memory message
    ) external {
        require(prove(leaf, proof, index), "!prove");
        process(message);
    }
}