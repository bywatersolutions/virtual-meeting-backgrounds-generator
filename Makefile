# Video-call backgrounds — common tasks
#
#   make deps     install system + Perl dependencies (Debian/Ubuntu)
#   make logos    regenerate the white/black logo assets from the master logo
#   make test     run the test suite (no network needed)
#   make parse    dry-run scrape of the offline fixture (no rsvg/write needed)
#   make fetch    stage 1: scrape the live site -> data/people.yaml
#   make render   stage 2: render anything changed from data/people.yaml -> staff/
#   make all      fetch then render
#   make force    re-render everything
#   make preview  render the synthetic sample person into ./preview
#   make commit   commit & push any new staff/ + data/ output (used by CI)
#   make clean    remove stray temp files

FIXTURE     := test/fixtures/about-us.html
PERL        := perl -Ilib
COMMIT_MSG  ?= chore: render backgrounds [skip ci]

.PHONY: deps logos test parse fetch render all force preview commit clean

deps:
	sudo apt-get update
	sudo apt-get install -y librsvg2-bin pngquant fonts-liberation libmojolicious-perl libyaml-pp-perl cpanminus
	perl -MMojo::DOM -e 1 || sudo cpanm --notest Mojolicious
	perl -MYAML::PP  -e 1 || sudo cpanm --notest YAML::PP

# Regenerate assets/bywater_logo_{white,black}.png from the master logo.
# Run this after changing assets/bywater_logo.png, then commit the results.
logos:
	$(PERL) scripts/make-mono-logos.pl

test:
	prove -Ilib t/

# Scrape the offline fixture and print the people — needs Mojo::DOM, not rsvg.
parse:
	DRY_RUN=1 ABOUT_URL=$(FIXTURE) $(PERL) scripts/fetch.pl

# Stage 1: scrape the live team page into data/people.yaml.
fetch:
	$(PERL) scripts/fetch.pl

# Stage 2: render backgrounds from data/people.yaml into staff/.
render:
	$(PERL) scripts/render.pl

# The whole pipeline: fetch fresh data, then render.
all: fetch render

force:
	FORCE=1 $(PERL) scripts/render.pl

# Render one sample person for all templates into ./preview (used by CI on PRs).
# Uses the offline fixture, so it never hits the network.
preview:
	rm -rf preview
	ABOUT_URL=test/fixtures/preview-person.html PEOPLE_FILE=preview/people.yaml $(PERL) scripts/fetch.pl
	OUTPUT_DIR=preview PEOPLE_FILE=preview/people.yaml $(PERL) scripts/render.pl

# Commit & push new staff/ + data/ output. No-op when there's nothing to commit.
commit:
	git config user.name  "Kyle M Hall"
	git config user.email "kyle@bywatersolutions.com"
	git add staff data
	@if git diff --cached --quiet; then \
		echo "No changes to commit."; \
	else \
		git commit -m "$(COMMIT_MSG)"; \
		git push; \
	fi

clean:
	find . -name '*.tmp.svg' -delete
	rm -rf preview
