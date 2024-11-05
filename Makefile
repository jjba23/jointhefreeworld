publish:
	rm -rf ./public .org-cache
	emacs -Q --batch -l ./jointhefreeworld-site.el --funcall jfw/publish
	mkdir -p ./public/cv && cp ./docs/cv/index.html ./public/cv/
	cp -Rf ./static ./public/static
dev:
	CI=false make publish
	darkhttpd ./public --port 50011
deploy:
	CI=true make publish
	rm -rf /srv/http/jointhefreeworld.org
	cp -rf public /srv/http/jointhefreeworld.org
