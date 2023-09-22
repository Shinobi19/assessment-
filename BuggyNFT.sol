// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AccessControlEnumerable} from "@openzeppelin/access/AccessControlEnumerable.sol";
import {Address} from "@openzeppelin/utils/Address.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC721Upgradeable} from "@openzeppelin-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OwnableUpgradeable, ContextUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {Pausable, Context} from "@openzeppelin/security/Pausable.sol";

import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {ROUTER} from "./interfaces/IUniswapV2Router02.sol";
import "@chainlink/contracts/src/v0.8/interfaces/FeedRegistryInterface.sol";
import "@chainlink/contracts/src/v0.8/Denominations.sol";

import {NFTFactory} from "./NFTFactory.sol";

// Keep storage in a separate contract so we can freely add to here and not mess
// up storage with upgrades. NEVER remove variables, only add
contract BuggyNFTStorageV1 {
    uint256 public nextNonce;
    NFTFactory public beacon;
    uint256 MAX_USER_MINT = 10;
    mapping(uint256 => uint256) public lastPrice;
    mapping(ERC20 => uint256) public feesCollected;
    // Tracks pending payments
    mapping(address => uint256) public pendingPayments;
    uint256 reward_multiplier = 2;
    uint256 reward_percentage = 1_00;
    uint256 reward_basis = 100_00;
    uint256 totalTokenSupply;
    uint256 largestBalance;
    // Chainlink feed registry
    FeedRegistryInterface internal registry;
    bytes32 public DOMAIN_SEPARATOR;

    // Add variables at the end of storage to prevent problems with upgrades
    // uint256 totalFeesCollected;
}

contract BuggyNFT is
    BuggyNFTStorageV1,
    BeaconProxy,
    AccessControlEnumerable,
    ERC721Upgradeable,
    OwnableUpgradeable,
    Pausable
{
    using Address for address;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(uint256 tokenId,address spender)");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant PROTOCOL_FEE = 5;
    uint256 public constant PROTOCOL_FEE_BASIS = 1000;
    uint256 public constant PRICE_INCREMENT = 1;
    uint256 public constant PRICE_INCREMENT_BASIS = 10;
    uint256 public constant SELLER_FEE = 1;
    uint256 public constant SELLER_FEE_BASIS = 5;
    ERC20 public constant ETHER = ERC20(address(0));

    event Mint(uint256 indexed tokenId, address indexed owner);
    event Burn(uint256 indexed tokenId, address indexed owner);

    constructor() BeaconProxy(msg.sender, "") {}

    function initialize(string memory name, string memory symbol)
        public
        initializer
    {
        beacon = NFTFactory(msg.sender);
        __ERC721_init(name, symbol);
        __Ownable_init();
        _setupRole(DEFAULT_ADMIN_ROLE, address(this));
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(PAUSER_ROLE, msg.sender);
        registry = FeedRegistryInterface(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 nameHash = keccak256("BuggyNFT");
        bytes32 versionHash = keccak256("1");
        DOMAIN_SEPARATOR = keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    ///                                     PUBLIC FUNCTIONS                                         ///
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice returns latest price
     * @param base asset converting from
     * @param quote asset converting to
     * @return price to convert base to quote
     */
    function getPrice(address base, address quote)
        public
        view
        returns (int256)
    {
        if (base == ROUTER.WETH()) {
            base = Denominations.ETH;
        }
        if (quote == ROUTER.WETH()) {
            quote = Denominations.ETH;
        }
        (
            uint80 roundID,
            int256 price,
            uint256 startedAt,
            uint256 timeStamp,
            uint80 answeredInRound
        ) = registry.latestRoundData(base, quote);
        return price;
    }

    /**
     * @notice burn a specific token
     * @param tokenId the id of token to burn
     */
    function safeBurn(uint256 tokenId) public whenNotPaused {
        require(
            _msgSender() == ownerOf(tokenId),
            "BuggyNFT: msg.sender does not own token"
        );
        _burn(tokenId);
        emit Burn(tokenId, _msgSender());
    }

    /**
     * @notice used by the owner to mint nfts for giveaways
     * @dev _safeMint checks caller is owner of this contract
     * @param to the address to mint tokens to
     * @param amount the amount of token to mint
     */
    function safeMint(address to, uint256 amount) public whenNotPaused {
        require(
            amount < MAX_USER_MINT,
            "BuggyNFT: Tried to mint too many tokens"
        );
        totalTokenSupply++;
        _safeMint(to, amount);
        emit Mint(amount, to);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    ///                                   EXTERNAL FUNCTIONS                                         ///
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Just in case I wrote a bug, we can pause the contract to make sure nobody
     * @notice loses money. But I know I didn't write any bugs.
     */
    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contracts after upgradeing beacon implementation
     */
    function unpause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice A token can be purchased by paying at least 10% more than the price the
     * @notice current owner paid. Don't be too sad, though. The original owner gets a
     * @notice cut.
     * @param tokenId id of the token
     * @param asset asset used to buy NFT
     * @param amount amount of asset to pay
     * @param pushPayment if the fee should implement push or pull pattern
     */
    function buy(
        uint256 tokenId,
        ERC20 asset,
        uint256 amount,
        bool pushPayment
    ) external payable whenNotPaused {
        address oldOwner = ownerOf(tokenId);
        uint256 oldPrice = lastPrice[tokenId];
        address msgSender = msg.sender;
        if (asset == ETHER) {
            require(msg.value == amount, "BuggyNFT: amount/value mismatch");
            uint256 fee = ((amount - oldPrice) * PROTOCOL_FEE) / PROTOCOL_FEE_BASIS;
            feesCollected[asset] += fee;
            amount -= fee;
        } else {
            require(!msgSender.isContract(), "BuggyNFT: no flash loan");
            asset.transferFrom(msgSender, address(this), amount);
            uint256 ethAmount = _ethValue(asset, amount);
            uint256 ethFee = ((ethAmount - oldPrice) * PROTOCOL_FEE) / PROTOCOL_FEE_BASIS;
            uint256 assetFee = (amount * ethFee) / ethAmount;
            feesCollected[asset] += assetFee;
            amount -= assetFee;
            asset.approve(address(ROUTER), amount);
            address[] memory path = new address[](2);
            path[0] = address(asset);
            path[1] = ROUTER.WETH();

            amount = ROUTER.swapExactTokensForETH(
                amount,
                0,
                path,
                address(this),
                block.timestamp
            )[1];
        }

        uint256 sellerFee = ((amount - oldPrice) * SELLER_FEE) / SELLER_FEE_BASIS;
        amount -= sellerFee;
        require(amount >= _nextPrice(oldPrice), "BuggyNFT: not enough");

        if (pushPayment) {
            payable(oldOwner).transfer(oldPrice + sellerFee);
        } else {
            pendingPayments[oldOwner] += oldPrice + sellerFee;
        }

        _transfer(oldOwner, msg.sender, tokenId);

        lastPrice[tokenId] += amount;
    }

    /**
     * @notice The tokenId is chosen randomly, but the amount of money to be paid has to
     * @notice be chosen beforehand. Make sure you spend a lot otherwise somebody else
     * @notice might buy your rare token out from under you!
     * @param asset asset used to buy NFT
     * @param amount amount of asset to pay
     */
    function mint(ERC20 asset, uint256 amount) external payable whenNotPaused {
        address msgSender = msg.sender;
        uint256 tokenId = uint256(
            keccak256(
                abi.encodePacked(
                    address(this),
                    blockhash(block.number - 1),
                    msgSender,
                    nextNonce
                )
            )
        );

        _safeMint(msgSender, tokenId);

        uint256 fee = (amount * PROTOCOL_FEE) / PROTOCOL_FEE_BASIS;
        feesCollected[asset] += fee;

        if (asset == ETHER) {
            require(msg.value == amount, "BuggyNFT: amount/value mismatch");
            amount -= fee;
        } else {
            require(!msgSender.isContract(), "BuggyNFT: no flash loan");
            asset.transferFrom(msgSender, address(this), amount);
            amount -= fee;
            asset.approve(address(ROUTER), amount);
            address[] memory path = new address[](2);
            path[0] = address(asset);
            path[1] = ROUTER.WETH();
            amount = ROUTER.swapExactTokensForETH(
                amount,
                0,
                path,
                address(this),
                block.timestamp
            )[1];
        }
        lastPrice[tokenId] = amount;
        nextNonce++;
    }

    function transferWithApproval(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) external {
        if(hasRole(_approvedRole(tokenId), msg.sender)) {
            _safeTransfer(from, to, tokenId, data);
        }
    }

    /**
     * @notice Approves an account to transfer token
     */
    function approve(
        uint256 tokenId,
        address spender,
        bytes calldata approveData
    ) external whenNotPaused {
        require(
            _msgSender() == ownerOf(tokenId),
            "BuggyNFT: Not owner of token"
        );
        require(
            _check(
                tokenId,
                spender,
                bytes4(keccak256("receiveApproval(uint256)")),
                approveData
            ),
            "BuggyNFT: rejected"
        );
        this.grantRole(_approvedRole(tokenId), spender);
        emit Approval(ownerOf(tokenId), spender, tokenId);
    }

    /**
     * @notice Allows other addresses to set approval without the owner spending gas. This
     * @notice is EIP712 compatible.
     */
    function permit(
        uint256 tokenId,
        address spender,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, tokenId, spender)
        );
        bytes32 signingHash = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        address signer = ecrecover(signingHash, v, r, s);
        require(ownerOf(tokenId) == signer, "BuggyNFT: not owner");
        this.grantRole(_approvedRole(tokenId), spender);
    }

    /**
     * @notice The user who owns the most NFTs can claim fees. The fee is taken in
     * @notice whatever token is paid, not just ETH.
     * @param receiver address to send fees to
     * @param asset token to withdraw from contract
     */
    function collect(address payable receiver, ERC20 asset)
        external
        whenNotPaused
    {
        require(
            balanceOf(msg.sender) >= largestBalance,
            "BuggyNFT: Don't own enough NFTs"
        );

        if (asset == ETHER) {
            (bool success, ) = receiver.call{value: feesCollected[asset]}("");
            require(success, "BuggyNFT: transfer failed");
        } else {
            asset.transfer(receiver, feesCollected[asset]);
        }
        delete feesCollected[asset];
    }

    /**
     * @notice Used to claim pendingPayments
     * @notice Users are recommended to use multisig accounts
     * @notice to prevent losses of their pending fees due to
     * @notice private key leaks
     */
    function claim() external whenNotPaused {
        require(
            pendingPayments[msg.sender] > 0,
            "BuggyNFT: not enough pending payment"
        );
        uint256 feesOwed = pendingPayments[msg.sender];
        // Use transfer to prevent reentrancy
        payable(msg.sender).transfer(feesOwed);
        delete pendingPayments[msg.sender];
    }

    function upgradeToAndCall(
        address newImplementation,
        bytes memory data,
        bool forceCall
    ) external onlyOwner {
        _upgradeToAndCall(newImplementation, data, forceCall);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    ///                                   INTERNAL FUNCTIONS                                         ///
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    function _check(
        uint256 tokenId,
        address receiver,
        bytes4 selector,
        bytes calldata data
    ) internal returns (bool) {
        if (!receiver.isContract()) {
            return true;
        }
        if (data.length == 0) {
            (bool success, bytes memory returnData) = receiver.call(
                abi.encodeWithSelector(selector, tokenId)
            );
            return
                success &&
                returnData.length == 4 &&
                abi.decode(returnData, (bytes4)) == selector;
        } else {
            (bool success, ) = receiver.call(data);
            return success;
        }
    }

    function _approvedRole(uint256 tokenId) internal pure returns (bytes32) {
        // Added owner of token to hash of approved role
        return
            keccak256(
                abi.encodePacked("APPROVED_ROLE", tokenId)
            );
    }

    function _nextPrice(uint256 tokenId) internal view returns (uint256) {
        return
            (lastPrice[tokenId] * (PRICE_INCREMENT + PRICE_INCREMENT_BASIS)) / PRICE_INCREMENT_BASIS;
    }

    function _ethValue(ERC20 asset, uint256 amount)
        internal
        view
        returns (uint256)
    {
        IUniswapV2Factory factory = IUniswapV2Factory(ROUTER.factory());
        IUniswapV2Pair pair = IUniswapV2Pair(
            factory.getPair(ROUTER.WETH(), address(asset))
        );
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (address(asset) == pair.token1()) {
            (reserve0, reserve1) = (reserve1, reserve0);
        }
        return ROUTER.getAmountOut(amount, reserve0, reserve1);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    ///                                  INHERITED FUNCTIONS                                         ///
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override whenNotPaused {}

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override {
        if (balanceOf(to) > largestBalance) {
            largestBalance = balanceOf(to);
        }
        revokeRole(
            _approvedRole(tokenId),
            getRoleMember(_approvedRole(tokenId), 0)
        );
    }

    function _msgData()
        internal
        view
        override(ContextUpgradeable, Context)
        returns (bytes calldata)
    {
        return super._msgData();
    }

    function _msgSender()
        internal
        view
        override(ContextUpgradeable, Context)
        returns (address sender)
    {
        if (beacon.isMediator(msg.sender)) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlEnumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    fallback() external payable override {}
}
