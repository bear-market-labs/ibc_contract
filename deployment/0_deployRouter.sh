echo "Deploying router:"
mnemonic=$FOUNDRY_TEST_MNEMONIC
rpc=$TENDERLY_RPC 
export WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
output=$(forge create --mnemonic="$mnemonic"  --rpc-url=$rpc  src/InverseBondingCurveRouter.sol:InverseBondingCurveRouter --constructor-args $WETH_ADDRESS)
echo "$output"
router_address=$(echo "$output" | grep -o 'Deployed to: [^ ]*' | awk '{print $3}')
export IBC_ROUTER_CONTRACT_ADDRESS=$router_address
echo "Router address: $router_address"
