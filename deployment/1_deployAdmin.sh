# deploy to tenderly mainnet fork network
# forge script script/DeployAdmin.s.sol:DeployAdminScript --broadcast --verify --sender 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266 --rpc-url https://rpc.tenderly.co/fork/cc2b5331-1bfa-4756-84ab-e2f2f63a91d5

echo "Deploying Admin Contract:"
echo "Deploying Curve Library:"
export WETH_ADDRESS="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
library_address=$IBC_CURVE_LIBRARY_ADDRESS #set to empty if we want redeploy
if [ -z "$library_address" ]
then
    output=$(forge create --private-key=$FOUNDRY_TEST_PRIVATE_KEY --rpc-url=$TENDERLY_RPC  src/CurveLibrary.sol:CurveLibrary )
    #--verify --verifier etherscan
    echo "$output"
    library_address=$(echo "$output" | grep -o 'Deployed to: [^ ]*' | awk '{print $3}')
    export IBC_CURVE_LIBRARY_ADDRESS=$library_address
    echo "New Created curve library address: "$library_address""   
else
    echo "Existing curve library address: "$library_address""
fi

