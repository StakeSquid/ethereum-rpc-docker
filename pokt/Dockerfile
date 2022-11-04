FROM poktnetwork/pocket-core:RC-0.9.1.3

COPY --chown=1005:1001 config.json /home/app/.pocket/config/config.json
COPY --chown=1005:1001 chains.json /home/app/.pocket/config/chains.json
COPY --chown=1005:1001 bootstrap.sh /home/app/.pocket/bootstrap.sh
RUN mkdir /home/app/.pocket/addrbook
RUN mkdir /home/app/.pocket/data
RUN chown -R 1005:1001 /home/app/.pocket/data


ENV POCKET_MAIN_SEEDS=03b74fa3c68356bb40d58ecc10129479b159a145@seed1.mainnet.pokt.network:20656,64c91701ea98440bc3674fdb9a99311461cdfd6f@seed2.mainnet.pokt.network:21656,0057ee693f3ce332c4ffcb499ede024c586ae37b@seed3.mainnet.pokt.network:22856,9fd99b89947c6af57cd0269ad01ecb99960177cd@seed4.mainnet.pokt.network:23856,f2a4d0ec9d50ea61db18452d191687c899c3ca42@seed5.mainnet.pokt.network:24856,f2a9705924e8d0e11fed60484da2c3d22f7daba8@seed6.mainnet.pokt.network:25856,582177fd65dd03806eeaa2e21c9049e653672c7e@seed7.mainnet.pokt.network:26856,2ea0b13ab823986cfb44292add51ce8677b899ad@seed8.mainnet.pokt.network:27856,a5f4a4cd88db9fd5def1574a0bffef3c6f354a76@seed9.mainnet.pokt.network:28856,d4039bd71d48def9f9f61f670c098b8956e52a08@seed10.mainnet.pokt.network:29856,5c133f07ed296bb9e21e3e42d5f26e0f7d2b2832@poktseed100.chainflow.io:26656,361b1936d3fbe516628ebd6a503920fc4fc0f6a7@seed.pokt.rivet.cloud:26656

CMD ["bash", "/home/app/.pocket/bootstrap.sh", "&&", "pocket", "start", "--seeds", "03b74fa3c68356bb40d58ecc10129479b159a145@seed1.mainnet.pokt.network:20656,64c91701ea98440bc3674fdb9a99311461cdfd6f@seed2.mainnet.pokt.network:21656,0057ee693f3ce332c4ffcb499ede024c586ae37b@seed3.mainnet.pokt.network:22856,9fd99b89947c6af57cd0269ad01ecb99960177cd@seed4.mainnet.pokt.network:23856,f2a4d0ec9d50ea61db18452d191687c899c3ca42@seed5.mainnet.pokt.network:24856,f2a9705924e8d0e11fed60484da2c3d22f7daba8@seed6.mainnet.pokt.network:25856,582177fd65dd03806eeaa2e21c9049e653672c7e@seed7.mainnet.pokt.network:26856,2ea0b13ab823986cfb44292add51ce8677b899ad@seed8.mainnet.pokt.network:27856,a5f4a4cd88db9fd5def1574a0bffef3c6f354a76@seed9.mainnet.pokt.network:28856,d4039bd71d48def9f9f61f670c098b8956e52a08@seed10.mainnet.pokt.network:29856,5c133f07ed296bb9e21e3e42d5f26e0f7d2b2832@poktseed100.chainflow.io:26656,361b1936d3fbe516628ebd6a503920fc4fc0f6a7@seed.pokt.rivet.cloud:26656", "--mainnet"]
