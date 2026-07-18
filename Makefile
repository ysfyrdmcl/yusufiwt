SHELL := /bin/sh

.PHONY: bootstrap generate test contract-test swift-test relay-test persistence-performance xcode-test lint clean

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

clean:
	rm -rf .build AgentControl.xcodeproj
