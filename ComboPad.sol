// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 *  ██████╗ ██████╗ ███╗   ███╗██████╗  ██████╗     ██████╗  █████╗ ██████╗
 *  ██╔════╝██╔═══██╗████╗ ████║██╔══██╗██╔═══██╗    ██╔══██╗██╔══██╗██╔══██╗
 *  ██║     ██║   ██║██╔████╔██║██████╔╝██║   ██║    ██████╔╝███████║██║  ██║
 *  ██║     ██║   ██║██║╚██╔╝██║██╔══██╗██║   ██║    ██╔═══╝ ██╔══██║██║  ██║
 *  ╚██████╗╚██████╔╝██║ ╚═╝ ██║██████╔╝╚██████╔╝    ██║     ██║  ██║██████╔╝
 *   ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═════╝  ╚═════╝     ╚═╝     ╚═╝  ╚═╝╚═════╝
 *
 *  COMBO PAD — NFT launchpad for Robinhood Chain (4663)
 *  Every NFT collection ships with its own ERC-20 token.
 *  A creator-chosen slice (1%–50%) of the token supply is split
 *  equally across all NFTs and vests linearly over a creator-chosen
 *  term, claimable by whoever holds each NFT at claim time.
 *
 *  Platform fee: 1% of all ETH mint revenue routes to the platform
 *  wallet, and every collection carries a 1% ERC-2981 royalty to the
 *  same wallet for secondary sales.
 *
 *  Deploy: compile ComboFactory with solc 0.8.24+ (optimizer on, 200 runs)
 *  and deploy it once on Robinhood Chain. Everything else is deployed
 *  by the factory per launch.
 *
 *  Notes:
 *  - Vesting starts at launch (combo creation), not at mint.
 *  - The allocation of NFTs that never mint stays locked in the
 *    vesting contract forever — effectively burned supply.
 *  - No admin keys, no upgradability, no pause. Once launched, a
 *    combo runs itself.
 */

/*//////////////////////////////////////////////////////////////
                       COMBO TOKEN — ERC-20
//////////////////////////////////////////////////////////////*/

contract ComboToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;
    uint16 public immutable holderBps;    // NFT holders' cut in basis points (100 = 1%, 5000 = 50%)

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @param supply       full supply in wei-units (18 decimals)
    /// @param _holderBps   NFT holders' cut in basis points (100–5000)
    /// @param vesting      receives the holders' cut
    /// @param creator      receives the rest
    constructor(
        string memory _name,
        string memory _symbol,
        uint256 supply,
        uint16 _holderBps,
        address vesting,
        address creator
    ) {
        name = _name;
        symbol = _symbol;
        totalSupply = supply;
        holderBps = _holderBps;

        uint256 holderCut = (supply * _holderBps) / 10000;
        balanceOf[vesting] = holderCut;
        balanceOf[creator] = supply - holderCut;
        emit Transfer(address(0), vesting, holderCut);
        emit Transfer(address(0), creator, supply - holderCut);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "COMBO: allowance");
            unchecked { allowance[from][msg.sender] = allowed - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "COMBO: zero address");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "COMBO: balance");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

/*//////////////////////////////////////////////////////////////
                        COMBO NFT — ERC-721
//////////////////////////////////////////////////////////////*/

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}

contract ComboNFT {
    string public name;
    string public symbol;
    string public baseURI;

    uint256 public immutable maxSupply;
    uint256 public immutable mintPrice;   // wei per NFT
    address public immutable creator;
    uint256 public totalMinted;           // ids are 1..totalMinted
    uint256 public proceeds;              // unclaimed creator mint revenue (99%)
    uint256 public platformProceeds;      // unclaimed platform fees (1%)

    address public constant PLATFORM = 0x9CD7C9196A4C1836A3DF089cb210272e07e6A5e5;
    uint256 public constant PLATFORM_FEE_BPS = 100;   // 1% of mint value
    uint256 public constant ROYALTY_BPS = 100;        // 1% ERC-2981 secondary royalty

    uint256 public constant MAX_PER_TX = 20;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Minted(address indexed to, uint256 firstId, uint256 quantity);
    event ProceedsWithdrawn(address indexed to, uint256 amount);

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _mintPrice,
        string memory _baseURI,
        address _creator
    ) {
        name = _name;
        symbol = _symbol;
        maxSupply = _maxSupply;
        mintPrice = _mintPrice;
        baseURI = _baseURI;
        creator = _creator;
    }

    /*────────────────────────── mint ──────────────────────────*/

    function mint(uint256 quantity) external payable {
        require(quantity >= 1 && quantity <= MAX_PER_TX, "COMBO: quantity");
        require(totalMinted + quantity <= maxSupply, "COMBO: sold out");
        require(msg.value == mintPrice * quantity, "COMBO: wrong price");

        uint256 firstId = totalMinted + 1;
        unchecked {
            totalMinted += quantity;
            balanceOf[msg.sender] += quantity;
            for (uint256 i = 0; i < quantity; i++) {
                uint256 id = firstId + i;
                _ownerOf[id] = msg.sender;
                emit Transfer(address(0), msg.sender, id);
            }
        }
        uint256 fee = (msg.value * PLATFORM_FEE_BPS) / 10000;
        platformProceeds += fee;
        proceeds += msg.value - fee;
        emit Minted(msg.sender, firstId, quantity);
    }

    /// Mint revenue is pull-based so a weird creator address can't brick minting.
    function withdrawProceeds() external {
        uint256 amount = proceeds;
        require(amount > 0, "COMBO: nothing to withdraw");
        proceeds = 0;
        (bool ok, ) = creator.call{value: amount}("");
        require(ok, "COMBO: withdraw failed");
        emit ProceedsWithdrawn(creator, amount);
    }

    /// Anyone can push accumulated platform fees to the platform wallet.
    function withdrawPlatformFees() external {
        uint256 amount = platformProceeds;
        require(amount > 0, "COMBO: nothing to withdraw");
        platformProceeds = 0;
        (bool ok, ) = PLATFORM.call{value: amount}("");
        require(ok, "COMBO: withdraw failed");
        emit ProceedsWithdrawn(PLATFORM, amount);
    }

    /// ERC-2981: 1% royalty on secondary sales to the platform wallet.
    function royaltyInfo(uint256, uint256 salePrice) external pure returns (address, uint256) {
        return (PLATFORM, (salePrice * ROYALTY_BPS) / 10000);
    }

    /*───────────────────────── erc-721 ─────────────────────────*/

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = _ownerOf[tokenId];
        require(owner != address(0), "COMBO: not minted");
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_ownerOf[tokenId] != address(0), "COMBO: not minted");
        if (bytes(baseURI).length == 0) return "";
        return string(abi.encodePacked(baseURI, _toString(tokenId)));
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        require(msg.sender == owner || isApprovedForAll[owner][msg.sender], "COMBO: not authorized");
        getApproved[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        address owner = ownerOf(tokenId);
        require(owner == from, "COMBO: wrong from");
        require(to != address(0), "COMBO: zero address");
        require(
            msg.sender == owner ||
            msg.sender == getApproved[tokenId] ||
            isApprovedForAll[owner][msg.sender],
            "COMBO: not authorized"
        );
        delete getApproved[tokenId];
        unchecked {
            balanceOf[from] -= 1;
            balanceOf[to] += 1;
        }
        _ownerOf[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data)
                    == IERC721Receiver.onERC721Received.selector,
                "COMBO: unsafe receiver"
            );
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC-165
            interfaceId == 0x80ac58cd || // ERC-721
            interfaceId == 0x5b5e139f || // ERC-721 Metadata
            interfaceId == 0x2a55205a;   // ERC-2981 Royalties
    }

    /// Convenience view for the frontend — fine as an eth_call, never on-chain.
    function tokensOfOwner(address owner) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf[owner];
        ids = new uint256[](n);
        if (n == 0) return ids;
        uint256 found = 0;
        for (uint256 id = 1; id <= totalMinted && found < n; id++) {
            if (_ownerOf[id] == owner) {
                ids[found] = id;
                found++;
            }
        }
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

/*//////////////////////////////////////////////////////////////
                COMBO VESTING — the holders' cut
//////////////////////////////////////////////////////////////*/

contract ComboVesting {
    ComboNFT public immutable nft;
    ComboToken public token;              // set once by the factory right after token deploy
    address public immutable factory;

    uint64 public immutable start;        // vesting starts at combo creation
    uint64 public immutable duration;     // seconds; 0 = fully unlocked at launch
    uint256 public perNft;                // full allocation per NFT (wei-units)

    mapping(uint256 => uint256) public claimed;   // tokenId => amount already claimed

    event Claimed(uint256 indexed tokenId, address indexed to, uint256 amount);

    constructor(address _nft, uint64 _duration) {
        nft = ComboNFT(_nft);
        factory = msg.sender;
        start = uint64(block.timestamp);
        duration = _duration;
    }

    function init(address _token) external {
        require(msg.sender == factory, "COMBO: not factory");
        require(address(token) == address(0), "COMBO: already set");
        token = ComboToken(_token);
        perNft = token.balanceOf(address(this)) / nft.maxSupply();
    }

    /// How much each NFT has vested so far (claimed or not).
    function vestedPerNft() public view returns (uint256) {
        uint256 elapsed = block.timestamp - start;
        if (duration == 0 || elapsed >= duration) return perNft;
        return (perNft * elapsed) / duration;
    }

    function claimable(uint256 tokenId) public view returns (uint256) {
        return vestedPerNft() - claimed[tokenId];
    }

    function claimableMany(uint256[] calldata tokenIds) external view returns (uint256 total) {
        uint256 vested = vestedPerNft();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            total += vested - claimed[tokenIds[i]];
        }
    }

    /// Claim vested tokens for one NFT. Pays whoever holds it right now.
    function claim(uint256 tokenId) public {
        require(nft.ownerOf(tokenId) == msg.sender, "COMBO: not the holder");
        uint256 amount = vestedPerNft() - claimed[tokenId];
        require(amount > 0, "COMBO: nothing claimable");
        claimed[tokenId] += amount;
        token.transfer(msg.sender, amount);
        emit Claimed(tokenId, msg.sender, amount);
    }

    function claimMany(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            claim(tokenIds[i]);
        }
    }
}

/*//////////////////////////////////////////////////////////////
                        COMBO FACTORY
//////////////////////////////////////////////////////////////*/

contract ComboFactory {
    struct Combo {
        address nft;
        address token;
        address vesting;
        address creator;
        uint64 createdAt;
    }

    Combo[] private _combos;

    event ComboCreated(
        uint256 indexed id,
        address nft,
        address token,
        address vesting,
        address indexed creator
    );

    /// Packed into a struct to keep the compiler's stack happy.
    /// @dev nftName/nftSymbol      collection name + symbol
    ///      maxSupply              NFT max supply (1..100000)
    ///      mintPrice              wei per NFT (0 = free mint)
    ///      baseURI                metadata base URI ("" is fine, can stay empty)
    ///      tokenName/tokenSymbol  attached token name + symbol
    ///      tokenSupplyWhole       token supply in whole tokens (18 decimals added here)
    ///      holderBps              NFT holders' cut in basis points (100 = 1% … 5000 = 50%)
    ///      vestingSeconds         linear vesting term for the holders' cut (0 = instant)
    struct LaunchParams {
        string nftName;
        string nftSymbol;
        uint256 maxSupply;
        uint256 mintPrice;
        string baseURI;
        string tokenName;
        string tokenSymbol;
        uint256 tokenSupplyWhole;
        uint16 holderBps;
        uint64 vestingSeconds;
    }

    function createCombo(LaunchParams calldata p) external returns (uint256 id) {
        require(p.maxSupply >= 1 && p.maxSupply <= 100000, "COMBO: nft supply 1-100000");
        require(p.tokenSupplyWhole >= 1, "COMBO: token supply");
        require(p.holderBps >= 100 && p.holderBps <= 5000, "COMBO: holder cut 1-50%");
        require(p.vestingSeconds <= 3650 days, "COMBO: vesting too long");

        ComboNFT nft = new ComboNFT(p.nftName, p.nftSymbol, p.maxSupply, p.mintPrice, p.baseURI, msg.sender);
        ComboVesting vesting = new ComboVesting(address(nft), p.vestingSeconds);
        ComboToken token = new ComboToken(
            p.tokenName,
            p.tokenSymbol,
            p.tokenSupplyWhole * 1e18,
            p.holderBps,
            address(vesting),
            msg.sender
        );
        vesting.init(address(token));

        id = _combos.length;
        _combos.push(Combo({
            nft: address(nft),
            token: address(token),
            vesting: address(vesting),
            creator: msg.sender,
            createdAt: uint64(block.timestamp)
        }));
        emit ComboCreated(id, address(nft), address(token), address(vesting), msg.sender);
    }

    function comboCount() external view returns (uint256) {
        return _combos.length;
    }

    function getCombo(uint256 id) external view returns (Combo memory) {
        return _combos[id];
    }

    /// Newest-first page for the frontend feed.
    function getCombosDesc(uint256 offset, uint256 limit) external view returns (Combo[] memory page) {
        uint256 n = _combos.length;
        if (offset >= n) return new Combo[](0);
        uint256 available = n - offset;
        uint256 count = available < limit ? available : limit;
        page = new Combo[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = _combos[n - 1 - offset - i];
        }
    }
}
