#!/bin/sh

# Xcode Cloud runs this script after cloning and before xcodebuild.
# It stamps the archive's build number (CFBundleVersion) with the
# unique, monotonically increasing Xcode Cloud build number so that
# every upload to App Store Connect has a higher build number than the
# previous one. Reusing a build number is the most common reason the
# "Prepare Build for App Store Connect" step fails.

set -e

if [ -z "$CI_BUILD_NUMBER" ]; then
    echo "CI_BUILD_NUMBER is not set; leaving CURRENT_PROJECT_VERSION unchanged."
    exit 0
fi

if [ -z "$CI_PRIMARY_REPOSITORY_PATH" ]; then
    echo "CI_PRIMARY_REPOSITORY_PATH is not set; cannot change directory."
    exit 0
fi

# Xcode Cloud checks the repository out at CI_PRIMARY_REPOSITORY_PATH.
cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "Setting build number to Xcode Cloud build $CI_BUILD_NUMBER"
xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
