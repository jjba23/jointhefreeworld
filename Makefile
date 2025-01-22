publish:
	rm -rf ./public .org-cache
	emacs -Q --batch -l ./jointhefreeworld-site.el --funcall jfw/publish
	mkdir -p ./public && cp -rf ./docs/cv ./public/
	cp -Rf ./static ./public/static
serve:
	darkhttpd ./public --index index.html --port 50011 
dev:
	watchexec -i "public/**" -r -e org,css,el -- "CI=false make publish && make serve"
deploy:
	CI=true make publish
	rm -rfv /srv/http/jointhefreeworld.org/index.html
	rm -rfv /srv/http/jointhefreeworld.org/blog
	rm -rfv /srv/http/jointhefreeworld.org/cv
	rm -rfv /srv/http/jointhefreeworld.org/portfolio
	rm -rfv /srv/http/jointhefreeworld.org/manuals/index.html
	cp -rfv public/* /srv/http/jointhefreeworld.org/
