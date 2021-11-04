import { task } from "hardhat/config";
import { checkVerification } from "../../helpers/etherscan-verification";
import { ConfigNames } from "../../helpers/configuration";
import { printContracts } from "../../helpers/misc-utils";
import { getFirstSigner } from "../../helpers/contracts-getters";
import { formatEther } from "@ethersproject/units";

task("bend:mainnet", "Deploy full enviroment")
  .addFlag("verify", "Verify contracts at Etherscan")
  .addFlag("skipRegistry", "Skip addresses provider registration at Addresses Provider Registry")
  .setAction(async ({ verify, skipRegistry }, DRE) => {
    const POOL_NAME = ConfigNames.Bend;
    await DRE.run("set-DRE");

    const signer = await getFirstSigner();

    console.log("Deployer:", await signer.getAddress(), "Balance:", formatEther(await signer.getBalance()));

    // Prevent loss of gas verifying all the needed ENVs for Etherscan verification
    if (verify) {
      checkVerification();
    }

    console.log("Migration started\n");

    //////////////////////////////////////////////////////////////////////////
    console.log("Deploy bnft registry");
    await DRE.run("full:deploy-bnft-registry", { verify, pool: POOL_NAME });

    console.log("Deploy bnft tokens");
    await DRE.run("full:deploy-bnft-tokens", { verify, pool: POOL_NAME });

    //////////////////////////////////////////////////////////////////////////
    console.log("Deploy address provider");
    await DRE.run("full:deploy-address-provider", { pool: POOL_NAME, skipRegistry });

    console.log("Deploy lend pool");
    await DRE.run("full:deploy-lend-pool", { pool: POOL_NAME });

    console.log("Deploy reserve oracle");
    await DRE.run("full:deploy-oracle-reserve", { pool: POOL_NAME });

    console.log("Deploy nft oracle");
    await DRE.run("full:deploy-oracle-nft", { pool: POOL_NAME });

    console.log("Deploy Data Provider");
    await DRE.run("full:data-provider", { pool: POOL_NAME });

    console.log("Deploy WETH Gateway");
    await DRE.run("full:deploy-weth-gateway", { pool: POOL_NAME });

    console.log("Deploy PUNK Gateway");
    await DRE.run("full:deploy-punk-gateway", { pool: POOL_NAME });

    console.log("Initialize lend pool");
    await DRE.run("full:initialize-lend-pool", { pool: POOL_NAME });

    if (verify) {
      printContracts();

      console.log("Veryfing general contracts");
      await DRE.run("verify:general", { all: true, pool: POOL_NAME });

      console.log("Veryfing reserves and nfts contracts");
      await DRE.run("verify:reserves", { pool: POOL_NAME });
      await DRE.run("verify:nfts", { pool: POOL_NAME });
    }

    console.log("\nFinished migrations");
    printContracts();
  });
