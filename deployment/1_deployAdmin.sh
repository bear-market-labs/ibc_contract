# run by deployer
echo "Deploying Admin Contract:"
mnemonic=$FOUNDRY_TEST_MNEMONIC
rpc=$TENDERLY_RPC  
export WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
fee_owner=$PROTOCOL_FEE_OWNER #"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
library_address=$IBC_CURVE_LIBRARY_ADDRESS #set to empty if we want redeploy
if [ -z "$library_address" ]
then
    echo "Deploying Curve Library:"
    output=$(forge create --mnemonic="$mnemonic" --rpc-url=$rpc  src/CurveLibrary.sol:CurveLibrary )
    echo "$output"
    library_address=$(echo "$output" | grep -o 'Deployed to: [^ ]*' | awk '{print $3}')
    export IBC_CURVE_LIBRARY_ADDRESS=$library_address
    echo "New Created curve library address: "$library_address""   
else
    echo "Existing curve library address: "$library_address""
fi
echo "Deploying Admin Contract:"
output=$(forge create --mnemonic="$mnemonic" --rpc-url=$rpc  src/InverseBondingCurveAdmin.sol:InverseBondingCurveAdmin \
    --libraries src/CurveLibrary.sol:CurveLibrary:"$IBC_CURVE_LIBRARY_ADDRESS" \
    --constructor-args $WETH_ADDRESS $IBC_ROUTER_CONTRACT_ADDRESS $PROTOCOL_FEE_OWNER)

echo "$output"
admin_address=$(echo "$output" | grep -o 'Deployed to: [^ ]*' | awk '{print $3}')
export IBC_ADMIN_CONTRACT_ADDRESS=$admin_address
call_result=$(cast call  --rpc-url=$rpc $IBC_ADMIN_CONTRACT_ADDRESS "owner()")
owner=$(cast --abi-decode "func()(address)" $call_result)
call_result=$(cast call  --rpc-url=$rpc $IBC_ADMIN_CONTRACT_ADDRESS "feeOwner()")
fee_owner=$(cast --abi-decode "func()(address)" $call_result)
call_result=$(cast call  --rpc-url=$rpc $IBC_ADMIN_CONTRACT_ADDRESS "factoryAddress()")
factory_address=$(cast --abi-decode "func()(address)" $call_result)
export IBC_FACTORY_CONTRACT_ADDRESS=$factory_address
echo "Admin contract address: $IBC_ADMIN_CONTRACT_ADDRESS"
echo "Admin contract owner address: $owner"
echo "Admin contract fee owner address: $fee_owner"
echo "Factory contract address: $IBC_FACTORY_CONTRACT_ADDRESS"

echo "------------------------------------------"
echo "Initiating ownership transfer to $OWNER"
owner=$OWNER

# two-stage transfer
# 1. current owner designates pending owner
cast send --mnemonic="$mnemonic" --rpc-url=$rpc $IBC_ADMIN_CONTRACT_ADDRESS "transferOwnership(address)" $owner

# 2. pending owner claims ownership; can also do this thru a frontend + metamask + ledger
#cast send --private-key="$OWNER_KEY" --rpc-url=$rpc $IBC_ADMIN_CONTRACT_ADDRESS "acceptOwnership()" 


