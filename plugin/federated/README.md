XGBoost Plugin for Federated Learning
=====================================

This folder contains the plugin for federated learning. Follow these steps to build and test it.

Install gRPC
------------
```shell
sudo apt-get install build-essential autoconf libtool pkg-config cmake ninja-build
git clone -b v1.45.2 https://github.com/grpc/grpc
cd grpc
git submodule update --init
cmake -S . -B build -GNinja -DABSL_PROPAGATE_CXX_STD=ON
cmake --build build --target install
```

Build the Plugin
----------------
```shell
# Under xgboost source tree.
mkdir build
cd build
cmake .. -GNinja -DPLUGIN_FEDERATED=ON
ninja
cd ../python-package
pip install -e .  # or equivalently python setup.py develop
```

Test Federated XGBoost
----------------------
```shell
# Under xgboost source tree.
cd tests/distributed
./runtests-federated.sh
```
