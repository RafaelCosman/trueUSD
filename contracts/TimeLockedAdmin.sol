pragma solidity ^0.4.18;

import 'zeppelin-solidity/contracts/ownership/HasNoEther.sol';
import 'zeppelin-solidity/contracts/ownership/HasNoTokens.sol';
import 'zeppelin-solidity/contracts/ownership/Ownable.sol';
import './TrueUSD.sol';

// The TimeLockedAdmin contract is intended to be the initial Owner of the TrueUSD
// contract and TrueUSD's AddressLists. It splits ownership into two accounts: an "admin" account and an
// "owner" account. The admin of TimeLockedAdmin can initiate two kinds of
// transactions: minting TrueUSD, and transferring ownership of the TrueUSD
// contract to a new owner. However, both of these transactions must be stored
// for ~1 day's worth of blocks first before they can be forwarded to the
// TrueUSD contract. In the event that the admin account is compromised, this
// setup allows the owner of TimeLockedAdmin (which can be stored extremely
// securely since it is never used in normal operation) to replace the admin.
// Once a day has passed, all mint and ownership transfer requests can be
// finalized by the beneficiary (the token recipient or the new owner,
// respectively). Requests initiated by an admin that has since been deposed
// cannot be finalized. The admin is also able to update TrueUSD's AddressLists
// (without a day's delay).
contract TimeLockedAdmin is Ownable, HasNoEther, HasNoTokens {

    // 24 hours, assuming a 15 second blocktime.
    // As long as this isn't too far off from reality it doesn't really matter.
    uint public constant blocksDelay = 24*60*60/15;

    struct MintOperation {
        address to;
        uint256 amount;
        address admin;
        uint deferBlock;
    }

    struct TransferOwnershipOperation {
        address newOwner;
        address admin;
        uint deferBlock;
    }

    struct ChangeBurnBoundsOperation {
        uint newMin;
        uint newMax;
        address admin;
        uint deferBlock;
    }

    struct ChangeInsuranceFeeOperation {
        uint80 newNumerator;
        uint80 newDenominator;
        address admin;
        uint deferBlock;
    }

    struct ChangeInsurerOperation {
        address newInsurer;
        address admin;
        uint deferBlock;
    }

    address public admin;
    TrueUSD public child;
    AddressList public canBurnWhiteList;
    AddressList public canReceiveMintWhitelist;
    AddressList public blackList;
    MintOperation[] public mintOperations;
    TransferOwnershipOperation public transferOwnershipOperation;
    ChangeBurnBoundsOperation public changeBurnBoundsOperation;
    ChangeInsuranceFeeOperation public changeInsuranceFeeOperation;
    ChangeInsurerOperation public changeInsurerOperation;

    modifier onlyAdmin() {
      require(msg.sender == admin);
      _;
    }

    // starts with no admin
    function TimeLockedAdmin(address _child, address _canBurnWhiteList, address _canReceiveMintWhitelist, address _blackList) public {
        child = TrueUSD(_child);
        canBurnWhiteList = AddressList(_canBurnWhiteList);
        canReceiveMintWhitelist = AddressList(_canReceiveMintWhitelist);
        blackList = AddressList(_blackList);
    }

    event MintOperationEvent(MintOperation op, uint opIndex, address indexed _to);
    event TransferOwnershipOperationEvent(TransferOwnershipOperation op);
    event ChangeBurnBoundsOperationEvent(ChangeBurnBoundsOperation op);
    event ChangeInsuranceFeeOperationEvent(ChangeInsuranceFeeOperation op);
    event ChangeInsurerOperationEvent(ChangeInsurerOperation op);
    event AdminshipTransferred(address indexed previousAdmin, address indexed newAdmin);

    // admin initiates a request to mint _amount TrueUSD for account _to
    function requestMint(address _to, uint256 _amount) public onlyAdmin {
        MintOperation memory op = MintOperation(_to, _amount, admin, block.number + blocksDelay);
        MintOperationEvent(op, mintOperations.length, _to);
        mintOperations.push(op);
    }

    // admin initiates a request to transfer ownership of the TrueUSD contract and all AddressLists to newOwner.
    // Can be used e.g. to upgrade this TimeLockedAdmin contract.
    function requestTransferOwnership(address newOwner) public onlyAdmin {
        TransferOwnershipOperation memory op = TransferOwnershipOperation(newOwner, admin, block.number + blocksDelay);
        TransferOwnershipOperationEvent(op);
        transferOwnershipOperation = op;
    }

    // admin initiates a request that the minimum and maximum amounts that any TrueUSD user can
    // burn become newMin and newMax
    function requestChangeBurnBounds(uint newMin, uint newMax) public onlyAdmin {
        ChangeBurnBoundsOperation memory op = ChangeBurnBoundsOperation(newMin, newMax, admin, block.number + blocksDelay);
        ChangeBurnBoundsOperationEvent(op);
        changeBurnBoundsOperation = op;
    }

    // admin initiates a request that the insurance fee be changed
    function requestChangeInsuranceFee(uint80 newNumerator, uint80 newDenominator) public onlyAdmin {
        ChangeInsuranceFeeOperation memory op = ChangeInsuranceFeeOperation(newNumerator, newDenominator, admin, block.number + blocksDelay);
        ChangeInsuranceFeeOperationEvent(op);
        changeInsuranceFeeOperation = op;
    }

    // admin initiates a request that the recipient of the insurance fee be changed to newInsurer
    function requestChangeInsurer(address newInsurer) public onlyAdmin {
        ChangeInsurerOperation memory op = ChangeInsurerOperation(newInsurer, admin, block.number + blocksDelay);
        ChangeInsurerOperationEvent(op);
        changeInsurerOperation = op;
    }

    // after a day, beneficiary of a mint request finalizes it by providing the
    // index of the request (visible in the MintOperationEvent accompanying the original request)
    function finalizeMint(uint index) public {
        MintOperation memory op = mintOperations[index];
        require(op.admin == admin); //checks that the requester's adminship has not been revoked
        require(op.deferBlock <= block.number); //checks that enough time has elapsed
        require(op.to == msg.sender); //only the recipient of the funds can finalize
        address to = op.to;
        uint256 amount = op.amount;
        delete mintOperations[index];
        child.mint(to, amount);
    }

    // after a day, prospective new owner of TrueUSD finalizes the ownership change
    function finalizeTransferOwnership() public {
        require(transferOwnershipOperation.admin == admin);
        require(transferOwnershipOperation.deferBlock <= block.number);
        require(transferOwnershipOperation.newOwner == msg.sender);
        address newOwner = transferOwnershipOperation.newOwner;
        delete transferOwnershipOperation;
        child.transferOwnership(newOwner);
        canBurnWhiteList.transferOwnership(newOwner);
        canReceiveMintWhitelist.transferOwnership(newOwner);
        blackList.transferOwnership(newOwner);
    }

    // after a day, admin finalizes the burn bounds change
    function finalizeChangeBurnBounds() public onlyAdmin {
        require(changeBurnBoundsOperation.admin == admin);
        require(changeBurnBoundsOperation.deferBlock <= block.number);
        uint newMin = changeBurnBoundsOperation.newMin;
        uint newMax = changeBurnBoundsOperation.newMax;
        delete changeBurnBoundsOperation;
        child.changeBurnBounds(newMin, newMax);
    }

    // after a day, admin finalizes the insurance fee change
    function finalizeChangeInsuranceFee() public onlyAdmin {
        require(changeInsuranceFeeOperation.admin == admin);
        require(changeInsuranceFeeOperation.deferBlock <= block.number);
        uint80 newNumerator = changeInsuranceFeeOperation.newNumerator;
        uint80 newDenominator = changeInsuranceFeeOperation.newDenominator;
        delete changeInsuranceFeeOperation;
        child.changeInsuranceFee(newNumerator, newDenominator);
    }

    // after a day, admin finalizes the insurance fees recipient change
    function finalizeChangeInsurer() public onlyAdmin {
        require(changeInsurerOperation.admin == admin);
        require(changeInsurerOperation.deferBlock <= block.number);
        address newInsurer = changeInsurerOperation.newInsurer;
        delete changeInsurerOperation;
        child.changeInsurer(newInsurer);
    }

    // Owner of this contract (immediately) replaces the current admin with newAdmin
    function transferAdminship(address newAdmin) public onlyOwner {
        AdminshipTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // admin (immediately) updates a whitelist/blacklist
    function updateList(address list, address entry, bool flag) public onlyAdmin {
        AddressList(list).changeList(entry, flag);
    }
}
