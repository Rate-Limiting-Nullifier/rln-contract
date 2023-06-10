// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RLNToken is ERC20 {

    constructor() ERC20("RLNT", "RLNT") {
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address _from,uint256 _amount) public{
        _burn(_from,_amount);
    }
}