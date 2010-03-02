v=3.81
ifeq ($(filter $(v),$(firstword $(sort $(MAKE_VERSION) $(v)))),)
$(error Sorry, Playdar requires GNU Make >= $(v))
endif

######################################################################## setup
ERLCFLAGS = -pa ebin +debug_info -W -I include
.DEFAULT_GOAL = all
.PHONY: all clean scanner

# [src/foo.erl, src/bar/tee.erl] -> [ebin/foo.beam, ebin/tee.beam]
define erl2beam
	$(foreach d, $(1), $(patsubst %.erl, ebin/%.beam, $(notdir $(wildcard $(d)/*.erl))))
endef

ebin/%.beam: %.erl | ebin
	erlc $(ERLCFLAGS) -o ebin $<

%.app: | ebin
	cp $< $@

######################################################################### deps
ERLYDTL_D = deps/erlydtl/src/erlydtl
MOCHIWEB_D = deps/mochiweb/src
MOCHIXPATH_D = deps/mochixpath/src
vpath %.erl $(MOCHIWEB_D) $(ERLYDTL_D) $(MOCHIXPATH_D)

ebin/mochixpath.app.in:
	sh $(MOCHIXPATH_D)/../ebin/mochixpath.app.in 0.1

ebin/mochixpath.app: ebin/mochixpath.app.in
	
$(ERLYDTL_D)/erlydtl_parser.erl: $(ERLYDTL_D)/erlydtl_parser.yrl
	erlc -o $(ERLYDTL_D) $<
ebin/erlydtl_compiler.beam: ebin/erlydtl_parser.beam
ebin/mochiweb.app: $(MOCHIWEB_D)/mochiweb.app
ebin/erlydtl.app: $(ERLYDTL_D)/erlydtl.app

################################################################# playdar-core
DIRS = src src/behaviours
BEAM = $(call erl2beam, $(DIRS)) ebin/playdar_default_config.beam
vpath %.erl $(wildcard $(DIRS))

ebin/script_resolver.beam: ebin/playdar_resolver.beam
ebin/playdar.app: src/playdar.app

ESCRIPT="\nmain(_)\n"'-> io:format("default_config()->~p.~n",[file:consult("etc/playdar.conf.example")]),halt(0).'
.default_config.hrl.escript:
	printf $(ESCRIPT) > $@
src/playdar_config.erl: include/default_config.hrl
include/default_config.hrl: .default_config.hrl.escript
	escript $< > $@

############################################################## playdar-modules
define MODULE_template
$(1)/ebin:
	mkdir -p $$@
$(1)/ebin/%.beam: $(1)/src/%.erl $(call erl2beam, src/behaviours) | $(1)/ebin
	erlc $(ERLCFLAGS) -o $(1)/ebin $$<

BEAM += $(patsubst %.erl, $(1)/ebin/%.beam, $(notdir $(wildcard $(1)/src/*.erl)))
EBIN += $(1)/ebin
endef

$(foreach d, $(wildcard playdar_modules/*), $(eval $(call MODULE_template, $(d))) )

############################################################################ c
TAGLIB_JSON_READER = playdar_modules/library/priv/taglib_driver/taglib_json_reader

$(TAGLIB_JSON_READER): $(TAGLIB_JSON_READER).cpp
	g++ `taglib-config --cflags` `taglib-config --libs` -o $@ $<

ifeq ($(shell uname), Darwin)
FSWATCHER = playdar_modules/library/priv/fswatcher_driver/fswatcher

$(FSWATCHER): $(FSWATCHER).c
	gcc -framework Carbon $< -o $@
endif

##################################################################### main bit
all: $(BEAM) ebin/playdar.app ebin/mochiweb.app ebin/erlydtl.app ebin/mochixpath.app

scanner: $(TAGLIB_JSON_READER) $(FSWATCHER)

clean:
	rm -rf ebin $(EBIN)
	rm -f $(ERLYDTL_PARSER) include/default_config.hrl .default_config.hrl.escript

$(BEAM): include/playdar.hrl $(call erl2beam, $(MOCHIWEB_D) $(ERLYDTL_D) $(MOCHIXPATH_D))

ebin:
	mkdir ebin
