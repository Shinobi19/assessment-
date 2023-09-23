

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
