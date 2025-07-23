# Makefile - installing and working with jointhefreeworld.org project

# Copyright © Josep Bigorra <jjbigorra@gmail.com>

# jointhefreeworld.org is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# jointhefreeworld.org is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with jointhefreeworld.org.  If not, see <https://www.gnu.org/licenses/>.

publish:
	rm -rf ./public .org-cache
	emacs -Q --batch -l ./jointhefreeworld-site.el --funcall jfw/publish
	mkdir -p ./public
	cp -Rf ./static ./public/static
	cp -Rf ./static/robots.txt ./public/robots.txt
serve:
	darkhttpd ./public --index index.html --port 50011 
dev:
	watchexec -i "public/**" -r -e org,css,el -- "CI=false make publish && make serve"
deploy:
	CI=true make publish
	rm -rfv /srv/http/jointhefreeworld.org/index.html
	rm -rfv /srv/http/jointhefreeworld.org/blog
	rm -rfv /srv/http/jointhefreeworld.org/portfolio
	rm -rfv /srv/http/jointhefreeworld.org/manuals/index.html
	cp -rfv public/* /srv/http/jointhefreeworld.org/
fmt:
	@-find ~+ -maxdepth 8 -name "*.el" -type f -exec emacs -Q --batch {} \
		-l $(shell realpath ./batch-indent.el) -f indent-file \;	
lint-css:
	stylelint --fix strict --config .stylelintrc.yml static/css/*.css
