// SPDX-License-Identifier: GPL-3.0
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/PiDynamicBPoolInterface.sol";
import "../interfaces/PiDynamicBFactoryInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PiDynamicActions {
    struct TokenConfig {
        address token;
        uint256 balance;
        uint256 targetDenorm;
        uint256 fromTimestamp;
        uint256 targetTimestamp;
    }

    function create(
        PiDynamicBFactoryInterface factory,
        string calldata name,
        string calldata symbol,
        uint256 minWeightPerSecond,
        uint256 maxWeightPerSecond,
        TokenConfig[] calldata tokens,
        uint[4] calldata fees,
        address communityFeeReceiver,
        bool finalize
    ) external returns (PiDynamicBPoolInterface pool) {
        pool = factory.newBPool(name, symbol, minWeightPerSecond, maxWeightPerSecond);
        pool.setSwapFee(fees[0]);
        pool.setCommunityFeeAndReceiver(fees[1], fees[2], fees[3], communityFeeReceiver);

        for (uint i = 0; i < tokens.length; i++) {
            TokenConfig memory tokenConfig = tokens[i];
            IERC20 token = IERC20(tokenConfig.token);
            require(token.transferFrom(msg.sender, address(this), tokenConfig.balance), "ERR_TRANSFER_FAILED");
            if (token.allowance(address(this), address(pool)) > 0) {
                token.approve(address(pool), 0);
            }
            token.approve(address(pool), tokenConfig.balance);
            pool.bind(
                tokenConfig.token,
                tokenConfig.balance,
                tokenConfig.targetDenorm,
                tokenConfig.fromTimestamp,
                tokenConfig.targetTimestamp
            );
        }

        if (finalize) {
            pool.finalize();
            require(pool.transfer(msg.sender, pool.balanceOf(address(this))), "ERR_TRANSFER_FAILED");
        } else {
            pool.setPublicSwap(true);
        }

        pool.setController(msg.sender);
    }
}