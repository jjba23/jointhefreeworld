publish:
	rm -rf ./public .org-cache
	emacs -Q --batch -l ./jointhefreeworld-site.el --funcall jfw/publish
	mkdir -p ./public/cv && cp ./docs/cv/index.html ./public/cv/
	cp -Rf ./static ./public/static
serve:
	darkhttpd ./public --port 50011
dev:
	watchexec -i "public/**" -r -e org,css,el -- "CI=false make publish && make serve"
deploy:
	CI=true make publish
	rm -rf /srv/http/jointhefreeworld.org
	cp -rf public /srv/http/jointhefreeworld.org
