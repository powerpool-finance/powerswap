
pragma solidity 0.6.12;

import "./interfaces/PiRouterInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


contract WrappedPiErc20 is ERC20 {
    using SafeMath for uint256;

    IERC20 public immutable token;
    address public router;

    event ChangeRouter(address indexed newRouter);
    event CallVoting(address indexed voting, bool indexed success, bytes4 indexed inputSig, bytes inputData, bytes outputData);

    modifier onlyRouter() {
        require(router == msg.sender, "WrappedPiErc20: caller is not the router");
        _;
    }

    constructor(address _token, address _router, string memory _name, string memory _symbol) public ERC20(_name, _symbol) {
        token = IERC20(_token);
        router = router;
    }

    function deposit(uint256 _amount) external {
        token.transferFrom(_msgSender(), address(this), _amount);
        _mint(_msgSender(), _amount);

        PiRouterInterface(router).wrapperCallback(0);
    }

    function withdraw(uint256 _amount) external {
        PiRouterInterface(router).wrapperCallback(_amount);

        ERC20(address(this)).transferFrom(_msgSender(), address(this), _amount);
        _burn(address(this), _amount);
        token.transfer(address(this), _amount);
    }

    function changeRouter(address _newRouter) external onlyRouter {
        router = _newRouter;
        emit ChangeRouter(router);
    }

    function approveToken(address _to, uint256 _amount) external onlyRouter {
        token.approve(address(this), _amount);
    }

    function callVoting(address voting, bytes4 signature, bytes calldata args, uint value) external onlyRouter {
        (bool success, bytes memory data) = voting.call{ value: value }(abi.encodePacked(signature, args));
        require(success, "NOT_SUCCESS");
        emit CallVoting(voting, success, signature, args, data);
    }

    function getWrappedBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}