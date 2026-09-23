.PHONY: build hub speaker watch-hub watch-speaker clean

build:
	go build -o builder build.go

hub:
	go run build.go hub

speaker:
	go run build.go speaker

watch-hub:
	go run build.go -watch hub

watch-speaker:
	go run build.go -watch speaker

clean:
	rm -rf hub/dist speaker/dist builder