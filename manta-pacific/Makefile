manta-up:
	@bash ./manta-up.sh
.PHONY: manta-up

manta-down:
	@(docker-compose -f docker-compose.yml down)
.PHONY: manta-down

manta-clean: manta-down
	docker image ls 'manta-pacific*' --format='{{.Repository}}' | xargs -r docker rmi
	docker volume ls --filter name=manta-pacific --format='{{.Name}}' | xargs -r docker volume rm
.PHONY: manta-clean
