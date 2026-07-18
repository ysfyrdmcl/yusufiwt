SHELL := /bin/sh

.PHONY: bootstrap generate test contract-test swift-test persistence-performance xcode-test lint clean

bootstrap:
	./Scripts/bootstrap.sh

generate:
	./Scripts/generate_project.sh

test: contract-test swift-test xcode-test

contract-test:
	./Tests/Contracts/test_repository_contract.sh
	./Tests/Contracts/test_project_contract.sh
	./Tests/Contracts/test_secret_hygiene.sh
	./Tests/Contracts/test_phase4_contract.sh
	./Tests/Contracts/test_phase5_contract.sh
	./Tests/Contracts/test_phase6_contract.sh
	./Tests/Contracts/test_phase7_contract.sh

swift-test:
	./Scripts/test_swift.sh

persistence-performance:
	./Scripts/test_persistence_performance.sh

xcode-test:
	./Scripts/test_all.sh

lint:
	./Scripts/lint.sh

clean:
	rm -rf .build AgentControl.xcodeproj
