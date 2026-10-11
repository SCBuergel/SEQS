.PHONY: help lint render unit integration fast prove mutate test

help: ## Show the available repository checks
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Run shell lint and Salt render smoke tests
	./test/run-tests.sh lint

render: ## Run detailed Salt and pillar render assertions
	./test/run-tests.sh render

unit: ## Run bash helper unit tests
	./test/run-tests.sh unit

integration: ## Run mocked end-to-end installer tests
	./test/run-tests.sh integration

fast: ## Run the fast lint and render layers
	./test/run-tests.sh fast

prove: ## Run the working tree's tests against the committed product code
	./test/run-tests.sh prove

mutate: ## Weaken each security check in turn and confirm a test fails
	./test/run-tests.sh mutate

test: ## Run every Qubes-free test layer
	./test/run-tests.sh
