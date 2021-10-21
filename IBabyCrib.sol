//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;
import "./IERC20.sol";

/**
 * Exempt Surge Interface
 */
interface IBabyCrib is IERC20 {
    function isExcludedFromRewards(address account) external view returns(bool);
    function getIncludedTotalSupply() external view returns (uint256);
}
