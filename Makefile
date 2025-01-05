.PHONY: api

build:
	docker build -t myridia/runner:latest .

default: build
