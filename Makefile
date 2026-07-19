SHELL := /bin/sh

.PHONY: bootstrap generate test contract-test swift-test relay-test persistence-performance xcode-test lint release-verify operations-verify build-mac-local package-mac-local install-mac-local uninstall-mac-local test-mac-local verify-mac-local-v1 clean

bootstrap:
	./Scripts/bootstrap.sh

generate:
	./Scripts/generate_project.sh

test: contract-test swift-test xcode-test

contract-test:
	./Tests/Contracts/test_repository_contract.sh
	./Tests/Contracts/test_project_contract.sh
	./Tests/Contracts/test_secret_hygiene.sh
	@for script in ./Tests/Contracts/test_phase*_contract.sh; do \
		"$$script"; \
	done

swift-test:
	./Scripts/test_swift.sh

relay-test:
	swift test --disable-sandbox --package-path Services/AgentControlRelay --scratch-path .build/relay

persistence-performance:
	./Scripts/test_persistence_performance.sh

xcode-test:
	./Scripts/test_all.sh

lint:
	./Scripts/lint.sh

release-verify:
	./Tests/Contracts/test_phase16_contract.sh
	./Tests/Contracts/test_phase17_contract.sh

operations-verify:
	ruby Scripts/verify_phase17.rb --structural

build-mac-local:
	./Scripts/build_mac_local.sh

package-mac-local:
	./Scripts/package_mac_local.sh

install-mac-local:
	./Scripts/install_mac_local.sh

uninstall-mac-local:
	./Scripts/uninstall_mac_local.sh

test-mac-local:
	./Scripts/test_mac_local.sh

verify-mac-local-v1:
	./Scripts/verify_mac_local_v1.sh

clean:
	rm -rf .build yusufiwt.xcodeproj AgentControl.xcodeproj
