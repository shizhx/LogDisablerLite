#!/bin/bash

rm "LogDisablerLite.zip"
pushd src || exit 1
mkdir -p ./system/lib64
zip -r "../LogDisablerLite.zip" ./*
popd || exit 2
