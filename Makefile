# Copyright © 2025-2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Version and build configuration variables
BUILD_CONFIGURATION ?= debug
WARNINGS_AS_ERRORS ?= true
# Extra swift build flags, appended last so callers can add to (rather than
# replace) the configuration above.
SWIFT_CONFIGURATION_EXTRA ?=
# Testability lets the unit tests `@testable import` internal symbols. SwiftPM
# already enables it for debug builds. In a release build it keeps every internal
# symbol exported and out of reach of dead-stripping, which makes the shipped
# binaries larger, so release builds leave it off unless a goal needs it (the
# test goals below turn it back on). Set ENABLE_TESTING=true or false to force it.
ENABLE_TESTING ?= $(if $(filter release,$(BUILD_CONFIGURATION)),false,true)
SWIFT_TESTING_FLAGS = $(if $(filter true,$(ENABLE_TESTING)),-Xswiftc -enable-testing)
# Recursively expanded so the release goal's BUILD_CONFIGURATION and the test
# goals' ENABLE_TESTING, both target-specific, take effect.
SWIFT_CONFIGURATION = $(if $(filter-out false,$(WARNINGS_AS_ERRORS)),-Xswiftc -warnings-as-errors) $(SWIFT_TESTING_FLAGS) $(SWIFT_CONFIGURATION_EXTRA)
# Goals that build or run tests need testability in every configuration.
build-tests test integration integration-only coverage coverage-all coverage-unit coverage-integration: ENABLE_TESTING = true
# Code-coverage instrumentation, layered onto the shared build stages. Empty for
# ordinary builds; the coverage-* targets opt in via a target-specific value so
# only those goals compile instrumented binaries.
COVERAGE_FLAG ?=
export RELEASE_VERSION ?= $(shell git describe --tags --always)
export GIT_COMMIT := $(shell git rev-parse HEAD)

# Commonly used locations
SWIFT := "/usr/bin/swift"
# Shared swift build invocation; callers append --build-tests / --product / etc.
SWIFT_BUILD = $(SWIFT) build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION)
DEST_DIR ?= /usr/local/
ROOT_DIR := $(shell git rev-parse --show-toplevel)
BUILD_BIN_DIR = $(shell $(SWIFT) build -c $(BUILD_CONFIGURATION) --show-bin-path)
STAGING_DIR := bin/$(BUILD_CONFIGURATION)/staging/
PKG_PATH := bin/$(BUILD_CONFIGURATION)/container-installer-unsigned.pkg
DSYM_DIR := bin/$(BUILD_CONFIGURATION)/bundle/container-dSYM
DSYM_PATH := bin/$(BUILD_CONFIGURATION)/bundle/container-dSYM.zip
CODESIGN_OPTS ?= --force --sign - --timestamp=none
# When CONTAINER_VMM_CR=1, sign the Linux runtime with hypervisor + virtualization entitlements.
RUNTIME_LINUX_ENTITLEMENTS ?= $(if $(filter 1,$(CONTAINER_VMM_CR)),signing/container-runtime-linux-cr.entitlements,signing/container-runtime-linux.entitlements)

# Strip the staged copies of the executables, never the build products, so the
# .dSYM bundles that `dsym` collects still match the stripped binaries (strip
# keeps the UUID). Releases strip by default; debug installs keep their symbols
# so lldb and backtraces stay useful during development. `-x` removes local
# symbols only. Plain `strip` (STRIP_OPTS=) shrinks the binaries further but
# also drops global symbols that dynamic linking does not need.
STRIP_BINARIES ?= $(if $(filter release,$(BUILD_CONFIGURATION)),true,false)
STRIP_OPTS ?= -x
# Executables the installer ships, relative to the staging directory.
# Note: bin/docker is a shell shim from scripts/docker — staged but not stripped.
STAGED_EXECUTABLES := \
	bin/container \
	bin/container-apiserver \
	libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux \
	libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet \
	libexec/container/plugins/container-core-images/bin/container-core-images \
	libexec/container/plugins/machine-apiserver/bin/machine-apiserver \
	libexec/container/plugins/cluster/bin/cluster \
	libexec/container/plugins/build/bin/build \
	libexec/container/plugins/builder/bin/builder \
	libexec/container/plugins/compose/bin/compose \
	libexec/container-plugins/compose/bin/compose
# The build products those executables are installed from, by product name.
# Keep in sync with the install steps in $(STAGING_DIR): `dsym` archives a dSYM
# for each one.
DSYM_PRODUCTS := \
	container \
	container-apiserver \
	container-runtime-linux \
	container-network-vmnet \
	container-core-images \
	machine-apiserver \
	cluster \
	container-build \
	container-builder \
	container-compose

# Default isolated application data root under the project directory so test runs do not touch your
# own installation. Override with APP_ROOT=/your/path, or APP_ROOT= (empty) to run against
# the default ~/Library/Application Support/com.apple.container.
APP_ROOT ?= $(ROOT_DIR)/.test-data

# Conditionally use a temporary data directory for integration tests
SYSTEM_START_OPTS :=
ifneq ($(strip $(APP_ROOT)),)
	SYSTEM_START_OPTS += --app-root "$(strip $(APP_ROOT))"
endif
ifneq ($(strip $(LOG_ROOT)),)
	SYSTEM_START_OPTS += --log-root "$(strip $(LOG_ROOT))"
endif

# swift test event-stream JSON output for the concurrent/global integration
# passes, only when LOG_ROOT is set.
CONCURRENT_EVENT_STREAM_OPTS :=
GLOBAL_EVENT_STREAM_OPTS :=
ifneq ($(strip $(LOG_ROOT)),)
	CONCURRENT_EVENT_STREAM_OPTS += --event-stream-output-path "$(strip $(LOG_ROOT))/integration-concurrent.json" --event-stream-version 6.3
	GLOBAL_EVENT_STREAM_OPTS += --event-stream-output-path "$(strip $(LOG_ROOT))/integration-global.json" --event-stream-version 6.3
endif

MACOS_VERSION := $(shell sw_vers -productVersion)
MACOS_MAJOR := $(shell echo $(MACOS_VERSION) | cut -d. -f1)

SUDO ?= sudo
.DEFAULT_GOAL := all

include Protobuf.Makefile

.PHONY: verify
verify: all test integration

.PHONY: all
all: container
all: init-block

# A prebuilt cluster-shim Linux binary, as CI provides. When empty, `build`
# builds it with `make -C cluster-shim build` if container services are
# running, and leaves it out otherwise.
CLUSTER_SHIM_BINARY ?=
CLUSTER_SHIM := $(if $(strip $(CLUSTER_SHIM_BINARY)),$(CLUSTER_SHIM_BINARY),cluster-shim/bin/cluster-shim)
CLUSTER_SHIM_MISSING := cluster-shim needs running container services; run 'container system start' or set CLUSTER_SHIM_BINARY

.PHONY: build
build:
	@echo Building container binaries...
	@$(SWIFT) --version
	@$(SWIFT_BUILD)
ifeq ($(strip $(CLUSTER_SHIM_BINARY)),)
	@if container system status > /dev/null 2>&1; then \
		echo Building cluster-shim...; \
		"$(MAKE)" -C cluster-shim build; \
	else \
		echo "Warning: skipping cluster-shim, so clusters from this build cannot use --shared-image-store. $(CLUSTER_SHIM_MISSING)." >&2; \
	fi
endif

.PHONY: build-tests
# Shared build stage for every test target: builds the test bundle (and the
# product binaries) once so the test targets can run with --skip-build. This is
# a distinct target from `build` so `make all test` builds products and tests as
# two separate steps rather than colliding on a single once-built target.
# COVERAGE_FLAG instruments the binaries when set by the coverage-* targets.
build-tests:
	@echo Building container binaries and tests...
	@$(SWIFT) --version
	@$(SWIFT_BUILD) --build-tests $(COVERAGE_FLAG)

.PHONY: coverage-all
coverage-all: build-tests
	@"$(MAKE)" BUILD_CONFIGURATION=$(BUILD_CONFIGURATION) DEST_DIR="$(ROOT_DIR)/" SUDO= install
	@"$(MAKE)" init-block

.PHONY: cli
cli:
	@echo Building container CLI...
	@$(SWIFT) --version
	@$(SWIFT_BUILD) --product container
	@echo Installing container CLI to bin/...
	@mkdir -p bin
	@install "$(BUILD_BIN_DIR)/container" "bin/container"
	@install -m 0755 scripts/docker "bin/docker"

.PHONY: container
# Install binaries under project directory
container: build
	@"$(MAKE)" BUILD_CONFIGURATION=$(BUILD_CONFIGURATION) DEST_DIR="$(ROOT_DIR)/" SUDO= install

.PHONY: release
release: BUILD_CONFIGURATION = release
release: all

.PHONY: init-block
init-block:
	@echo Building initfs if containerization is in edit mode
	@scripts/install-init.sh $(SYSTEM_START_OPTS)

.PHONY: install
install: installer-pkg
	@echo Installing container installer package
	@if [ -z "$(SUDO)" ] ; then \
		temp_dir=$$(mktemp -d) ; \
		xar -xf $(PKG_PATH) -C $${temp_dir} ; \
		(cd "$(DEST_DIR)" && pax -rz -f $${temp_dir}/Payload) ; \
		rm -rf $${temp_dir} ; \
	else \
		$(SUDO) installer -pkg $(PKG_PATH) -target / ; \
	fi

$(STAGING_DIR):
	@echo Installing container binaries from "$(BUILD_BIN_DIR)" into "$(STAGING_DIR)"...
	@rm -rf "$(STAGING_DIR)"
	@mkdir -p "$(join $(STAGING_DIR), bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/container-core-clusters/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/resources)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/cluster/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/cluster/resources)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/cluster-hoststore/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/build/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/builder/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/plugins/compose/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container-plugins/compose/bin)"
	@mkdir -p "$(join $(STAGING_DIR), libexec/container/helpers)"

	@install "$(BUILD_BIN_DIR)/container" "$(join $(STAGING_DIR), bin/container)"
	@install -m 0755 scripts/docker "$(join $(STAGING_DIR), bin/docker)"
	@install "$(BUILD_BIN_DIR)/container-apiserver" "$(join $(STAGING_DIR), bin/container-apiserver)"
	@install "$(BUILD_BIN_DIR)/container-runtime-linux" "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux)"
	@install Sources/Plugins/RuntimeLinux/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/config.toml)"
	@# F6: CR is the default VMM; override with CONTAINER_VMM_BACKEND=vz
	@printf '$(if $(filter 1,$(CONTAINER_VMM_CR)),cr,vz)\n' > "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/bin/vmm-backend)"
	@if [ ! -f resources/network-dns/hosts-dns ]; then \
		echo "error: resources/network-dns/hosts-dns missing; run 'make hosts-dns' before packaging." >&2; \
		exit 1; \
	fi
	@install -m 0755 resources/network-dns/hosts-dns "$(join $(STAGING_DIR), libexec/container/helpers/hosts-dns)"
	@install "$(BUILD_BIN_DIR)/container-network-vmnet" "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet)"
	@install Sources/Plugins/NetworkVmnet/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/config.toml)"
	@install "$(BUILD_BIN_DIR)/container-core-images" "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/bin/container-core-images)"
	@install "$(BUILD_BIN_DIR)/container-core-clusters" "$(join $(STAGING_DIR), libexec/container/plugins/container-core-clusters/bin/container-core-clusters)"
	@install Sources/Plugins/CoreImages/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/config.toml)"
	@install Sources/Plugins/CoreClusters/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/container-core-clusters/config.toml)"
	@install "$(BUILD_BIN_DIR)/machine-apiserver" "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/bin/machine-apiserver)"
	@install Sources/Plugins/MachineAPIServer/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/config.toml)"
	@install Sources/Plugins/MachineAPIServer/Resources/init "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/resources/init)"
	@install "$(BUILD_BIN_DIR)/cluster" "$(join $(STAGING_DIR), libexec/container/plugins/cluster/bin/cluster)"
	@install Sources/Plugins/Cluster/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/cluster/config.toml)"
	@install Sources/Plugins/Cluster/Resources/kindnet.yaml "$(join $(STAGING_DIR), libexec/container/plugins/cluster/resources/kindnet.yaml)"
	@if [ -f "$(CLUSTER_SHIM)" ]; then \
		install -m 0755 "$(CLUSTER_SHIM)" "$(join $(STAGING_DIR), libexec/container/plugins/cluster/resources/cluster-shim)"; \
	else \
		echo "Warning: packaging without cluster-shim; $(CLUSTER_SHIM) does not exist." >&2; \
	fi
	@install "$(BUILD_BIN_DIR)/cluster-hoststore" "$(join $(STAGING_DIR), libexec/container/plugins/cluster-hoststore/bin/cluster-hoststore)"
	@install Sources/Plugins/ClusterHostStore/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/cluster-hoststore/config.toml)"
	@install "$(BUILD_BIN_DIR)/container-build" "$(join $(STAGING_DIR), libexec/container/plugins/build/bin/build)"
	@install Sources/Plugins/ContainerBuild/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/build/config.toml)"
	@install "$(BUILD_BIN_DIR)/container-builder" "$(join $(STAGING_DIR), libexec/container/plugins/builder/bin/builder)"
	@install Sources/Plugins/ContainerBuilder/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/builder/config.toml)"
	@install "$(BUILD_BIN_DIR)/container-compose" "$(join $(STAGING_DIR), libexec/container/plugins/compose/bin/compose)"
	@install Sources/Plugins/ContainerCompose/config.toml "$(join $(STAGING_DIR), libexec/container/plugins/compose/config.toml)"
	# PluginLoader also scans libexec/container-plugins (legacy layout); keep both in sync.
	@install "$(BUILD_BIN_DIR)/container-compose" "$(join $(STAGING_DIR), libexec/container-plugins/compose/bin/compose)"
	@install Sources/Plugins/ContainerCompose/config.toml "$(join $(STAGING_DIR), libexec/container-plugins/compose/config.toml)"

	@echo Install update script
	@install scripts/update-container.sh "$(join $(STAGING_DIR), bin/update-container.sh)"
	@echo Install uninstaller script
	@install scripts/uninstall-container.sh "$(join $(STAGING_DIR), bin/uninstall-container.sh)"
	@echo Install NFS-capable / preferred kernel helpers
	@install -m 0755 scripts/install-nfs-kernel.sh "$(join $(STAGING_DIR), bin/install-container-nfs-kernel)"
	@install -m 0755 scripts/install-recommended-kernel.sh "$(join $(STAGING_DIR), bin/install-container-recommended-kernel)"
	@echo Install Recipe B engine sock helper
	@install -m 0755 scripts/install-engine-sock.sh "$(join $(STAGING_DIR), bin/install-container-engine-sock)"

.PHONY: installer-pkg
installer-pkg: $(STAGING_DIR)
	@if [ "$(STRIP_BINARIES)" = "true" ]; then \
		echo Stripping container binaries...; \
		for bin in $(STAGED_EXECUTABLES); do \
			strip $(STRIP_OPTS) "$(STAGING_DIR)$$bin" || exit 1; \
		done; \
	fi
	@echo Signing container binaries...
	@codesign $(CODESIGN_OPTS) --identifier com.apple.container.cli "$(join $(STAGING_DIR), bin/container)"
	@codesign $(CODESIGN_OPTS) --identifier com.apple.container.apiserver "$(join $(STAGING_DIR), bin/container-apiserver)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/container-core-images/bin/container-core-images)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/container-core-clusters/bin/container-core-clusters)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. --entitlements=$(RUNTIME_LINUX_ENTITLEMENTS) "$(join $(STAGING_DIR), libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. --entitlements=signing/container-network-vmnet.entitlements "$(join $(STAGING_DIR), libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/machine-apiserver/bin/machine-apiserver)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/cluster/bin/cluster)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/cluster-hoststore/bin/cluster-hoststore)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/build/bin/build)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/builder/bin/builder)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container/plugins/compose/bin/compose)"
	@codesign $(CODESIGN_OPTS) --prefix=com.apple.container. "$(join $(STAGING_DIR), libexec/container-plugins/compose/bin/compose)"

	@echo Creating application installer
	@pkgbuild --root "$(STAGING_DIR)" --identifier com.apple.container-installer --install-location /usr/local --version ${RELEASE_VERSION} $(PKG_PATH)
	@rm -rf "$(STAGING_DIR)"

.PHONY: dsym
dsym:
	@echo Collecting debug symbols...
	@rm -rf "$(DSYM_DIR)"
	@mkdir -p "$(DSYM_DIR)"
	@bin_dir="$(BUILD_BIN_DIR)"; \
	for product in $(DSYM_PRODUCTS); do \
		if [ -d "$$bin_dir/$$product.dSYM" ]; then \
			cp -a "$$bin_dir/$$product.dSYM" "$(DSYM_DIR)" || exit 1; \
		else \
			echo "The build produced no dSYM for $$product, generating one..."; \
			dsymutil "$$bin_dir/$$product" -o "$(DSYM_DIR)/$$product.dSYM" || exit 1; \
		fi; \
		built=$$(dwarfdump --uuid "$$bin_dir/$$product" | awk '{print $$2}' | sort); \
		archived=$$(dwarfdump --uuid "$(DSYM_DIR)/$$product.dSYM" | awk '{print $$2}' | sort); \
		if [ -z "$$built" ] || [ "$$built" != "$$archived" ]; then \
			echo "error: the dSYM for $$product does not match the built binary"; \
			exit 1; \
		fi; \
	done

	@echo Packaging the debug symbols...
	@(cd "$(dir $(DSYM_DIR))" ; zip -r $(notdir $(DSYM_PATH)) $(notdir $(DSYM_DIR)))

.PHONY: test
test: build-tests
	@$(SWIFT) test --skip-build -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --skip TestCLI --skip IntegrationTests $(if $(strip $(FILTER)),--filter '$(strip $(FILTER))')

.PHONY: install-kernel
install-kernel:
	@echo Stopping system before installing kernel
	@bin/container system stop || true
	@echo Starting system to install kernel
	@bin/container --debug system start --timeout 60 --enable-kernel-install $(SYSTEM_START_OPTS)

# Stock kernel install for NFS users (CONTAINER_PREFERRED_KERNEL=nfs, default).
# Kata `system kernel set --recommended` often omits `nfs` (see docs/volumes.md#nfs-mounts).
# Prefer `make install-recommended-kernel` (alias below) or this target directly.
.PHONY: install-nfs-kernel
install-nfs-kernel: container
	@chmod +x scripts/install-nfs-kernel.sh
	@CONTAINER_BIN="$(ROOT_DIR)/bin/container" ./scripts/install-nfs-kernel.sh

# Preferred kernel install. Default CONTAINER_PREFERRED_KERNEL=nfs → install-nfs-kernel.
# Set CONTAINER_PREFERRED_KERNEL=kata for the historic Kata --recommended tarball.
.PHONY: install-recommended-kernel
install-recommended-kernel: container
	@chmod +x scripts/install-recommended-kernel.sh scripts/install-nfs-kernel.sh
	@CONTAINER_BIN="$(ROOT_DIR)/bin/container" ./scripts/install-recommended-kernel.sh


# Coverage report generation helpers
# Directory that swift test spits out raw coverage data
COV_DATA_DIR = $(shell $(SWIFT) test --show-coverage-path | xargs dirname)
COV_REPORT_FILE = $(ROOT_DIR)/code-coverage-report
COVERAGE_OUTPUT_DIR := $(ROOT_DIR)/coverage-reports
# One bundle per test target, e.g. ContainerOSTests.xctest/Contents/MacOS/ContainerOSTests.
TEST_BINARY = $(foreach b,$(wildcard $(BUILD_BIN_DIR)/*.xctest),-object $(b)/Contents/MacOS/$(basename $(notdir $(b))))
# All product binaries that may be instrumented for coverage.
# Used as additional -object args to llvm-cov for all reports.
COV_BINARIES := \
	$(BUILD_BIN_DIR)/container \
	$(BUILD_BIN_DIR)/container-apiserver \
	$(BUILD_BIN_DIR)/container-runtime-linux \
	$(BUILD_BIN_DIR)/container-network-vmnet \
	$(BUILD_BIN_DIR)/container-core-images \
	$(BUILD_BIN_DIR)/container-core-clusters \
	$(BUILD_BIN_DIR)/machine-apiserver \
	$(BUILD_BIN_DIR)/container-build \
	$(BUILD_BIN_DIR)/container-builder
COV_OBJECT_FLAGS := $(patsubst %,-object %,$(COV_BINARIES))
# Set of files we do not want to get caught in the coverage generation
LLVM_COV_IGNORE := \
	--ignore-filename-regex=".build/" \
	--ignore-filename-regex="/Tests/" \
	--ignore-filename-regex="/ContainerTestSupport/" \
	--ignore-filename-regex=".pb.swift" \
	--ignore-filename-regex=".proto" \
	--ignore-filename-regex=".grpc.swift"

# Generate JSON + HTML coverage reports and a coverage-percent.txt from a profdata file.
# $(1) = profdata path, $(2) = tier name (unit/integration/combined), $(3) = additional -object flags (optional)
define GENERATE_COV_REPORTS
	@echo Exporting $(2) coverage JSON...
	@xcrun llvm-cov export --compilation-dir=`pwd` \
		-instr-profile=$(1) \
		$(LLVM_COV_IGNORE) \
		$(TEST_BINARY) $(3) > $(COVERAGE_OUTPUT_DIR)/$(2)/coverage-summary.json
	@echo Generating $(2) coverage HTML report...
	@xcrun llvm-cov show --compilation-dir=`pwd` --format=html \
		-instr-profile=$(1) \
		$(LLVM_COV_IGNORE) \
		-output-dir=$(COVERAGE_OUTPUT_DIR)/$(2)/html \
		$(TEST_BINARY) $(3)
	@echo Extracting $(2) coverage percentages...
	@jq -r '.data[0].totals as $$t | \
		"Coverage summary:", \
		"  lines:     \($$t.lines.percent | . * 100 | round | . / 100)% (\($$t.lines.covered) of \($$t.lines.count))", \
		"  functions: \($$t.functions.percent | . * 100 | round | . / 100)% (\($$t.functions.covered) of \($$t.functions.count))", \
		"  regions:   \($$t.regions.percent | . * 100 | round | . / 100)% (\($$t.regions.covered) of \($$t.regions.count))"' \
		$(COVERAGE_OUTPUT_DIR)/$(2)/coverage-summary.json > $(COVERAGE_OUTPUT_DIR)/$(2)/coverage-percent.txt
	@echo "-- $(2) coverage --"
	@cat $(COVERAGE_OUTPUT_DIR)/$(2)/coverage-percent.txt
endef

# PARALLEL_WIDTH controls --experimental-maximum-parallelization-width for the
# concurrent pass. WARMUP_FILTER, CONCURRENT_FILTER, and SERIAL_FILTER select
# the three phases.
PARALLEL_WIDTH ?= $(shell sysctl -n hw.physicalcpu)
WARMUP_FILTER = ImageWarmup/

# Concurrent suites: Test*.swift files whose names do NOT end in Serial.
CONCURRENT_TEST_SUITES ?= $(sort $(addsuffix /,$(basename $(notdir \
    $(shell find Tests/IntegrationTests -name 'Test*.swift' \
            ! -name '*Serial.swift' 2>/dev/null)))))
CONCURRENT_FILTER = $(subst $(space),|,$(strip $(CONCURRENT_TEST_SUITES)))

# Serial suites: Test*.swift files whose names end in Serial.
SERIAL_TEST_SUITES ?= $(sort $(addsuffix /,$(basename $(notdir \
    $(shell find Tests/IntegrationTests -name 'Test*Serial.swift' 2>/dev/null)))))
SERIAL_FILTER = $(subst $(space),|,$(strip $(SERIAL_TEST_SUITES)))

INTEGRATION_SWIFT_EXTRA ?=
INTEGRATION_POST_TEST ?=
# Environment prefix applied to the `container system start` invocation. Empty for
# ordinary runs; coverage runs set LLVM_PROFILE_FILE here so launchd-managed helper
# (XPC service) processes emit their own profraw data.
INTEGRATION_PROFILE_ENV ?=

PRESERVE_KERNELS ?= false
# Default scratch root under the project directory so container build can access context
# subdirectories (macOS restricts access to /var/folders from the container binary).
# Override with SCRATCH_ROOT=/your/path on the command line.
SCRATCH_ROOT ?= $(ROOT_DIR)/.test-scratch

define RUN_INTEGRATION
	@echo Ensuring apiserver stopped before the CLI integration tests...
	@bin/container system stop && sleep 3 && scripts/ensure-container-stopped.sh
	@if [ -n "$(APP_ROOT)" ]; then \
		mkdir -p $(APP_ROOT) ; \
		if [ "$(PRESERVE_KERNELS)" = "true" ]; then \
			echo "Clearing application data under $(APP_ROOT) (preserving kernels)..." ; \
			find "$(APP_ROOT)" -mindepth 1 -maxdepth 1 ! -name kernels -exec rm -rf {} + ; \
		else \
			echo "Clearing application data under $(APP_ROOT)..." ; \
			find "$(APP_ROOT)" -mindepth 1 -maxdepth 1 -exec rm -rf {} + ; \
		fi ; \
	fi
	@echo Running the integration tests...
	@$(INTEGRATION_PROFILE_ENV) bin/container --debug system start --timeout 60 --enable-kernel-install $(SYSTEM_START_OPTS) && \
	{ \
		if [ -n "$(APP_ROOT)" ]; then CONTAINER_APP_ROOT=$(APP_ROOT) && export CONTAINER_APP_ROOT ; fi ; \
		CLITEST_LOG_ROOT=$(LOG_ROOT) && export CLITEST_LOG_ROOT ; \
		CLITEST_SCRATCH_ROOT=$(SCRATCH_ROOT) && export CLITEST_SCRATCH_ROOT ; \
		CONTAINER_CLI_PATH=$(ROOT_DIR)/bin/container && export CONTAINER_CLI_PATH ; \
		echo "==> Starting warmup tests" && \
		$(SWIFT) test $(INTEGRATION_SWIFT_EXTRA) -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --filter "$(WARMUP_FILTER)" && \
		echo "==> Starting $(words $(CONCURRENT_TEST_SUITES)) test suites concurrently (width=$(PARALLEL_WIDTH))" && \
		$(SWIFT) test --skip-build $(INTEGRATION_SWIFT_EXTRA) -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) $(CONCURRENT_EVENT_STREAM_OPTS) --experimental-maximum-parallelization-width $(PARALLEL_WIDTH) --filter "$(CONCURRENT_FILTER)" && \
		echo "==> Starting $(words $(SERIAL_TEST_SUITES)) test suites serially" && \
		$(SWIFT) test --skip-build $(INTEGRATION_SWIFT_EXTRA) -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) $(GLOBAL_EVENT_STREAM_OPTS) --experimental-maximum-parallelization-width 1 --filter "$(SERIAL_FILTER)" ; \
		exit_code=$$? ; \
		$(INTEGRATION_POST_TEST) \
		echo Ensuring apiserver stopped after the CLI integration tests ; \
		scripts/ensure-container-stopped.sh ; \
		exit $${exit_code} ; \
	}
endef

# --- Behavioral parity gates -------------------------------------------------------------------
# These run real commands and assert on observable output. Unlike the older source-grep
# targets below, they fail when behavior regresses, not only when a comment is removed.
#
# cli-surface needs no running system (it walks `--help` for every command), so it is safe
# anywhere. The rest need a started system and are isolated by APP_ROOT in CI; do not point
# them at a machine whose containers/volumes you care about without reading each script's
# SAFETY note (the lifecycle script only touches uniquely named resources and label-scoped prunes).
.PHONY: parity-cli-surface
parity-cli-surface:
	@chmod +x scripts/parity/cli-surface.sh scripts/parity/compose-matrix-drift.sh
	@BIN_DIR="$(BUILD_BIN_DIR)" bash scripts/parity/cli-surface.sh
	@bash scripts/parity/compose-matrix-drift.sh

# Self-contained and ISOLATED: like `make integration`, this stops any running system, starts a
# fresh one under APP_ROOT (default ./.test-data), runs the live harnesses against THAT, and stops it
# again. The harnesses therefore never see a developer's real containers, volumes or networks.
# (A previous version ran against whatever system was up and an unscoped prune deleted a
# developer's volumes.) It does not depend on `container`: it tests the installed bin/ (CI builds
# it earlier in the same job; locally run `make container` first). Locally this leaves the
# system stopped afterwards, exactly as `make integration` does.
.PHONY: parity-behavioral
parity-behavioral: parity-cli-surface
	@test -x "$(ROOT_DIR)/bin/container" || { echo "bin/container not installed: run 'make container' first" >&2; exit 2; }
	@test -x "$(ROOT_DIR)/bin/docker" || { echo "bin/docker not installed: run 'make container' first" >&2; exit 2; }
	@test -n "$(strip $(APP_ROOT))" || { echo "parity-behavioral refuses to run against the default system: set APP_ROOT to an isolated directory" >&2; exit 2; }
	@chmod +x scripts/parity/t2-docker-corpus.sh scripts/parity/t3-compose-corpus.sh scripts/parity/t2-bridge-streams.sh scripts/parity/t2-bridge-hostconfig.sh scripts/parity/t2-bridge-lifecycle.sh
	@echo "Stopping any running system; parity harnesses run against an isolated root: $(APP_ROOT)"
	@bin/container system stop || true
	@sleep 3 && scripts/ensure-container-stopped.sh
	@mkdir -p "$(APP_ROOT)"
	@bin/container --debug system start --timeout 60 --enable-kernel-install $(SYSTEM_START_OPTS) && \
	{ \
		export CONTAINER_APP_ROOT="$(APP_ROOT)" CONTAINER_BIN="$(ROOT_DIR)/bin/container" DOCKER_BIN="$(ROOT_DIR)/bin/docker" BRIDGE_BIN="$(BUILD_BIN_DIR)/container-docker-api-bridge" ; \
		export COMPOSE_SKIP_PRODUCTION="$${COMPOSE_SKIP_PRODUCTION:-1}" COMPOSE_SKIP_NFS="$${COMPOSE_SKIP_NFS:-1}" ; \
		rc=0 ; \
		for h in t2-docker-corpus t3-compose-corpus t2-bridge-streams t2-bridge-hostconfig t2-bridge-lifecycle ; do \
			echo "==> $$h" ; \
			bash scripts/parity/$$h.sh || rc=1 ; \
		done ; \
		echo "Stopping the isolated system" ; \
		scripts/ensure-container-stopped.sh ; \
		exit $$rc ; \
	}

# T3 against the CURRENT system. The harness refuses unless the running apiserver's app root matches
# CONTAINER_APP_ROOT (so it cannot touch a developer's real containers); `make parity-behavioral` runs it
# on an isolated system, with the heavy 08-10 and NFS 06 fixtures skipped by default (set
# COMPOSE_SKIP_PRODUCTION=0 / COMPOSE_SKIP_NFS=0 to include them). PARITY_ALLOW_REAL_SYSTEM=1 overrides.
.PHONY: compose-parity
compose-parity: container
	@chmod +x scripts/parity/t3-compose-corpus.sh
	CONTAINER_BIN="$(ROOT_DIR)/bin/container" bash scripts/parity/t3-compose-corpus.sh

.PHONY: compose-doctor-smoke
compose-doctor-smoke: container
	@chmod +x scripts/parity/compose-doctor-smoke.sh
	CONTAINER_BIN="$(ROOT_DIR)/bin/container" bash scripts/parity/compose-doctor-smoke.sh

# NOTE: the l1/l2/l3/l4/f2-f5/c3 targets below are STATIC CHECKS: they grep source/docs for symbols and
# comments and pass even when the build is broken. They are not evidence of behavior. Use
# `make parity-behavioral` for that.
# L1 contract: preferred kernel install defaults to NFS-capable (no guest mount).
.PHONY: l1-nfs-default
l1-nfs-default:
	@chmod +x scripts/parity/l1-nfs-default.sh
	@bash scripts/parity/l1-nfs-default.sh

# L4 contract: Recipe B first-class for docker.sock consumers.
.PHONY: l4-recipe-b-sock
l4-recipe-b-sock: container
	@chmod +x scripts/parity/l4-recipe-b-sock.sh
	CONTAINER_BIN="$(ROOT_DIR)/bin/container" bash scripts/parity/l4-recipe-b-sock.sh

# L2 contract: shared virtiofs named-volume plane.
.PHONY: l2-shared-volumes
l2-shared-volumes:
	@chmod +x scripts/parity/l2-shared-volumes.sh
	@bash scripts/parity/l2-shared-volumes.sh

# L3 contract: network-scoped exact aliases.
.PHONY: l3-network-scoped-aliases
l3-network-scoped-aliases:
	@chmod +x scripts/parity/l3-network-scoped-aliases.sh
	@bash scripts/parity/l3-network-scoped-aliases.sh

# F2 contract: Compose extends merge.
.PHONY: f2-compose-extends
f2-compose-extends: container
	@chmod +x scripts/parity/f2-compose-extends.sh
	CONTAINER_BIN="$(ROOT_DIR)/bin/container" bash scripts/parity/f2-compose-extends.sh

.PHONY: bridge-corpus-parity
bridge-corpus-parity: container
	@chmod +x scripts/parity/t2-bridge-corpus.sh
	CONTAINER_BIN="$(ROOT_DIR)/bin/container" bash scripts/parity/t2-bridge-corpus.sh

# F4 CR virtio-net hotplug gate (static; set F4_LIVE=1 for live connect smoke).
.PHONY: f4-net-hotplug
f4-net-hotplug:
	@chmod +x scripts/parity/f4-net-hotplug.sh
	@bash scripts/parity/f4-net-hotplug.sh

# C3 blk hotplug caller gate (RuntimeService → CRVirtualMachineInstance.hotplug).
.PHONY: c3-blk-hotplug
c3-blk-hotplug:
	@chmod +x scripts/parity/c3-blk-hotplug.sh
	@bash scripts/parity/c3-blk-hotplug.sh

# F5 in-core sock remains opt-in (static gate).
.PHONY: f5-incore-sock
f5-incore-sock:
	@chmod +x scripts/parity/f5-incore-sock.sh
	@bash scripts/parity/f5-incore-sock.sh

.PHONY: f3-devices-unrestricted
f3-devices-unrestricted:
	@chmod +x scripts/parity/f3-devices-unrestricted.sh
	@bash scripts/parity/f3-devices-unrestricted.sh

.PHONY: f4-vz-net-hotplug
f4-vz-net-hotplug:
	@chmod +x scripts/parity/f4-vz-net-hotplug.sh
	@bash scripts/parity/f4-vz-net-hotplug.sh

.PHONY: f4-vz-net-hotplug-live
f4-vz-net-hotplug-live: container
	@chmod +x scripts/parity/f4-vz-net-hotplug-live.sh
	CONTAINER_BIN="$(ROOT_DIR)/bin/container" bash scripts/parity/f4-vz-net-hotplug-live.sh

.PHONY: r6-container-gui
r6-container-gui:
	@chmod +x scripts/parity/r6-container-gui.sh
	@bash scripts/parity/r6-container-gui.sh

.PHONY: t2-client-smoke
t2-client-smoke: container
	@chmod +x scripts/parity/t2-client-smoke.sh
	CONTAINER_BIN="$(ROOT_DIR)/bin/container" bash scripts/parity/t2-client-smoke.sh


.PHONY: integration
integration: container init-block
	@echo "HOSTNAME: $$(hostname)"
	$(RUN_INTEGRATION)

.PHONY: integration-only
integration-only: init-block
	@echo "HOSTNAME: $$(hostname)"
	$(RUN_INTEGRATION)

.PHONY: coverage-integration
coverage-integration: INTEGRATION_SWIFT_EXTRA = --skip-build --enable-code-coverage
coverage-integration: INTEGRATION_POST_TEST = cp $(COV_DATA_DIR)/*.profraw $(COVERAGE_OUTPUT_DIR)/integration/ || true ;
# Continuous mode (%c) mmaps the profraw and syncs counters live. The XPC helper
# services are torn down by `launchctl bootout` (SIGTERM/SIGKILL) rather than
# exiting cleanly, so a non-continuous profile (written by an atexit handler that
# never runs on SIGKILL) would lose the helpers' counters. %p-%m keeps each
# process/module profile in its own file so they don't collide.
coverage-integration: INTEGRATION_PROFILE_ENV = LLVM_PROFILE_FILE=$(COVERAGE_OUTPUT_DIR)/integration/%p-%m%c.profraw
coverage-integration: coverage-all
	@echo "HOSTNAME: $$(hostname)"
	@mkdir -p $(COVERAGE_OUTPUT_DIR)/integration
	@rm -f $(COVERAGE_OUTPUT_DIR)/integration/*.profraw
	$(RUN_INTEGRATION)
	@echo Merging integration coverage profdata...
	@xcrun llvm-profdata merge -sparse $(COVERAGE_OUTPUT_DIR)/integration/*.profraw -o $(COVERAGE_OUTPUT_DIR)/integration/default.profdata
	$(call GENERATE_COV_REPORTS,$(COVERAGE_OUTPUT_DIR)/integration/default.profdata,integration,$(COV_OBJECT_FLAGS))

empty :=
space := $(empty) $(empty)

# Opt the coverage targets in to instrumentation. The value propagates to the
# shared build-tests target so compilation is instrumented when necessary.
coverage coverage-all coverage-unit coverage-integration: COVERAGE_FLAG = --enable-code-coverage -Xswiftc -DCONTAINER_COVERAGE

.PHONY: coverage
# Merge the per-tier profdata from coverage-unit and coverage-integration into a
# combined report. Each prerequisite target produces its own tier report first.
coverage: coverage-unit coverage-integration
	@echo Merging combined coverage profdata...
	@mkdir -p $(COVERAGE_OUTPUT_DIR)/combined
	@xcrun llvm-profdata merge -sparse \
		$(COVERAGE_OUTPUT_DIR)/unit/default.profdata \
		$(COVERAGE_OUTPUT_DIR)/integration/default.profdata \
		-o $(COVERAGE_OUTPUT_DIR)/combined/default.profdata
	$(call GENERATE_COV_REPORTS,$(COVERAGE_OUTPUT_DIR)/combined/default.profdata,combined,$(COV_OBJECT_FLAGS))

.PHONY: coverage-unit
coverage-unit: build-tests
	@echo Running unit test coverage...
	@rm -f $(COV_DATA_DIR)/*.profraw
	@mkdir -p $(COVERAGE_OUTPUT_DIR)/unit
	@$(SWIFT) test --skip-build --enable-code-coverage -c $(BUILD_CONFIGURATION) $(SWIFT_CONFIGURATION) --skip TestCLI --skip IntegrationTests
	@echo Merging unit coverage profdata...
	@xcrun llvm-profdata merge -sparse $(COV_DATA_DIR)/*.profraw -o $(COVERAGE_OUTPUT_DIR)/unit/default.profdata
	$(call GENERATE_COV_REPORTS,$(COVERAGE_OUTPUT_DIR)/unit/default.profdata,unit,$(COV_OBJECT_FLAGS))

.PHONY: fmt
fmt: swift-fmt update-licenses

.PHONY: check
check: swift-fmt-check check-licenses

.PHONY: swift-fmt
SWIFT_SRC = $(shell find . -type f -name '*.swift' -not -path "*/.*" -not -path "*.pb.swift" -not -path "*.grpc.swift" -not -path "*/checkouts/*")
swift-fmt:
	@echo Applying the standard code formatting...
	@$(SWIFT) format --recursive --configuration .swift-format -i $(SWIFT_SRC)

swift-fmt-check:
	@echo Applying the standard code formatting...
	@$(SWIFT) format lint --recursive --strict --configuration .swift-format-nolint $(SWIFT_SRC)

.PHONY: update-licenses
update-licenses:
	@echo Updating license headers...
	@./scripts/ensure-hawkeye-exists.sh
	@.local/bin/hawkeye format --fail-if-unknown --fail-if-updated false

.PHONY: check-licenses
check-licenses:
	@echo Checking license headers existence in source files...
	@./scripts/ensure-hawkeye-exists.sh
	@.local/bin/hawkeye check --fail-if-unknown

.PHONY: pre-commit
pre-commit:
	$(eval HOOKS_DIR := $(shell git rev-parse --git-path hooks))
	cp scripts/pre-commit.fmt $(HOOKS_DIR)/
	touch $(HOOKS_DIR)/pre-commit
	cat $(HOOKS_DIR)/pre-commit | grep -v 'hooks/pre-commit\.fmt' > /tmp/pre-commit.new || true
	echo 'PRECOMMIT_NOFMT=$${PRECOMMIT_NOFMT} $$(git rev-parse --git-path hooks/pre-commit.fmt)' >> /tmp/pre-commit.new
	mv /tmp/pre-commit.new $(HOOKS_DIR)/pre-commit
	chmod +x $(HOOKS_DIR)/pre-commit
	@./scripts/ensure-hawkeye-exists.sh

.PHONY: serve-docs
serve-docs:
	@echo 'to browse: open http://127.0.0.1:8000/container/documentation/'
	@rm -rf _serve
	@mkdir -p _serve
	@cp -a _site _serve/container
	@python3 -m http.server --bind 127.0.0.1 --directory ./_serve

.PHONY: docs
docs:
	@echo Updating API documentation...
	@rm -rf _site
	@scripts/make-docs.sh _site container

.PHONY: demo-gif
demo-gif:
	@echo Recording the README demo...
	@scripts/record-demo.sh

.PHONY: hosts-dns
# Cross-compile the in-guest hosts-dns helper (Linux/arm64 static) via alpine.
# Depend on `cli` (not `container`/installer) so packaging can require the helper
# without a circular hosts-dns ↔ installer dependency.
hosts-dns: cli
	@mkdir -p resources/network-dns
	@test -f resources/network-dns/hosts-dns.c || (echo "missing resources/network-dns/hosts-dns.c" >&2; exit 1)
	@echo Building hosts-dns helper...
	@CONTAINER_BIN="$${CONTAINER_BIN:-$(ROOT_DIR)/bin/container}"; \
	  "$$CONTAINER_BIN" run --rm \
	    --mount "type=bind,source=$(ROOT_DIR)/resources/network-dns,target=/src" \
	    alpine:3.20 \
	    sh -c 'apk add --no-cache gcc musl-dev >/dev/null && cc -static -O2 -s -o /src/hosts-dns /src/hosts-dns.c'
	@mkdir -p libexec/container/helpers
	@install -m 0755 resources/network-dns/hosts-dns libexec/container/helpers/hosts-dns
	@echo Installed libexec/container/helpers/hosts-dns

.PHONY: cleancontent
cleancontent:
	@bin/container system stop || true
	@echo Cleaning the content...
	@rm -rf ~/Library/Application\ Support/com.apple.container

.PHONY: clean
clean: cleanclustershim cleantest cleanbuild

.PHONY: cleanclustershim
cleanclustershim:
	@echo Cleaning cluster-shim build files...
	@"$(MAKE)" -C cluster-shim clean

.PHONY: cleanbuild
cleanbuild:
	@echo Cleaning build files...
	@rm -rf bin/ libexec/
	@rm -rf _site _serve
	@rm -f $(COV_REPORT_FILE)
	@rm -rf $(COVERAGE_OUTPUT_DIR)
	@$(SWIFT) package clean

.PHONY: cleantest
cleantest:
	@echo Stopping container services...
	@bin/container system stop 2>/dev/null || true
	@scripts/ensure-container-stopped.sh -a || true
	@if [ -n "$(APP_ROOT)" ]; then echo "Removing $(APP_ROOT)..." ; rm -rf "$(APP_ROOT)" ; fi
	@echo "Removing $(SCRATCH_ROOT)..."
	@rm -rf "$(SCRATCH_ROOT)"
