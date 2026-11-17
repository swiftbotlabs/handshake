// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Demo origin contract for PROOF bounties: a tiny job board whose `run` emits the event a bounty can wait for.
///         Example bounty: "pay whoever first runs job 7 (with at least 3 units of work) before Friday".
contract KeeperJobs {
    event JobRun(uint256 indexed jobId, address indexed keeper, uint256 work);

    mapping(uint256 => bool) public done;

    function run(uint256 jobId_, uint256 work_) external {
        require(!done[jobId_], "already run");
        done[jobId_] = true;
        emit JobRun(jobId_, msg.sender, work_);
    }
}
