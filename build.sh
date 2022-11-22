#!/bin/bash

rm "LogDisablerLite.zip"
pushd src || exit 1
zip -r "../LogDisablerLite.zip" ./*
popd || exit 2
