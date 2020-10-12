REBAR:=rebar3

test:
	$(REBAR) eunit -c
	$(REBAR) ct -c
	$(REBAR) cover --verbose

dialyzer:
	$(REBAR) dialyzer

fmt:
	$(REBAR) as dev fmt

lint:
	$(REBAR) as dev lint

doc:
	$(REBAR) edoc

pre-commit: fmt lint doc

.PHONY: test fmt lint doc pre-commit
