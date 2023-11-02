# forge script script/DeployRouter.s.sol:DeployRouterScript --broadcast --verify --rpc-url https://rpc.tenderly.co/fork/cc2b5331-1bfa-4756-84ab-e2f2f63a91d5
echo "Deploying router:"
export WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
output=$(forge create --private-key=$FOUNDRY_TEST_PRIVATE_KEY --rpc-url=$TENDERLY_RPC  src/InverseBondingCurveRouter.sol:InverseBondingCurveRouter --constructor-args $WETH_ADDRESS)
#--verify --verifier etherscan
echo "$output"
router_address=$(echo "$output" | grep -o 'Deployed to: [^ ]*' | awk '{print $3}')
export IBC_ROUTER_ADDRESS=$router_address
echo "Router address: $router_address"
