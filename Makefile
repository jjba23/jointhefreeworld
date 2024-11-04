publish:
	rm -rf ./public .org-cache
	emacs -Q --batch -l ./jointhefreeworld-site.el --funcall jfw/publish
	mkdir -p ./public/cv && cp ./docs/cv/index.html ./public/cv/
server: publish
	darkhttpd ./public --port 50011
