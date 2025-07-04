#ifdef REFERENCE_TRACKING

#ifdef FAST_REFERENCE_TRACKING
// typecache of types that almost certainly have no refs, and thus can be safely skipped when finding references
GLOBAL_LIST_INIT_TYPED(reftracker_skip_typecache, /alist, init_reftracker_skip_typecache())

/proc/init_reftracker_skip_typecache()
	. = alist()
	for(var/base_type in list(
		/icon,
		/regex,
		/datum/armor,
		/datum/asset_cache_item,
		/datum/book_info,
		/datum/card,
		/datum/cassette_data,
		/datum/chat_payload,
		/datum/color_palette,
		/datum/component/mirage_border, // only turf and mirage holder refs
		/datum/gas_mixture,
		/datum/greyscale_layer,
		/datum/instrument_key,
		/datum/lighting_object, // only contains turf and MA refs
		/datum/media_track,
		/datum/movespeed_modifier,
		/datum/painting,
		/datum/paper_input,
		/datum/physiology,
		/datum/plant_gene/core,
		/datum/plant_gene/reagent,
		/datum/qdel_item,
		/datum/stack_recipe,
		/datum/tlv,
		/datum/weakref,
		/turf/open/space/basic,
		/turf/cordon,
		/obj/effect/abstract/mirage_holder, // only a turf ref i think?
		// no need to scan these two
		/datum/controller/subsystem/demo,
		/datum/controller/subsystem/garbage,
		// stuff below isn't 100% guaranteed to be ref-free, but they're prolly not an issue
		/datum/light_source,
		/datum/lighting_corner,
		/datum/component/connect_loc_behalf,
		/datum/reagent/consumable/nutriment,
		/datum/chatmessage,
		/atom/movable/outdoor_effect,
	))
		for(var/type in typesof(base_type))
			.[type] = TRUE
#endif

/datum/proc/find_references(skip_alert)
	running_find_references = type
	if(usr?.client)
		if(usr.client.running_find_references)
			log_reftracker("CANCELLED search for references to a [usr.client.running_find_references].")
			usr.client.running_find_references = null
			running_find_references = null
			//restart the garbage collector
			SSgarbage.can_fire = TRUE
			SSgarbage.update_nextfire(reset_time = TRUE)
			return

		if(!skip_alert && tgui_alert(usr,"Running this will lock everything up for about 5 minutes.  Would you like to begin the search?", "Find References", list("Yes", "No")) != "Yes")
			running_find_references = null
			return

	//this keeps the garbage collector from failing to collect objects being searched for in here
	SSgarbage.can_fire = FALSE

	if(usr?.client)
		usr.client.running_find_references = type

	log_reftracker("Beginning search for references to a [type].")

	var/starting_time = world.time

	log_reftracker("Refcount for [type]: [refcount(src)]")

	//Time to search the whole game for our ref
	DoSearchVar(GLOB, "GLOB", search_time = starting_time) //globals
	log_reftracker("Finished searching globals")

	//Yes we do actually need to do this. The searcher refuses to read weird lists
	//And global.vars is a really weird list
	var/global_vars = list()
	for(var/key in global.vars)
		global_vars[key] = global.vars[key]

	DoSearchVar(global_vars, "Native Global", search_time = starting_time)
	log_reftracker("Finished searching native globals")

#ifdef FAST_REFERENCE_TRACKING
	var/alist/skip_types = GLOB.reftracker_skip_typecache
#endif

	for(var/datum/thing in world) //atoms (don't beleive its lies)
#ifdef FAST_REFERENCE_TRACKING
		if(skip_types[thing.type])
			continue
#endif
		DoSearchVar(thing, "World -> [thing.type]", search_time = starting_time)
	log_reftracker("Finished searching atoms")

	for(var/datum/thing) //datums
#ifdef FAST_REFERENCE_TRACKING
		if(skip_types[thing.type])
			continue
#endif
		DoSearchVar(thing, "Datums -> [thing.type]", search_time = starting_time)
	log_reftracker("Finished searching datums")

	//Warning, attempting to search clients like this will cause crashes if done on live. Watch yourself
#ifndef REFERENCE_DOING_IT_LIVE
	for(var/client/thing) //clients
		DoSearchVar(thing, "Clients -> [thing.type]", search_time = starting_time)
	log_reftracker("Finished searching clients")
#endif

	log_reftracker("Completed search for references to a [type].")

	if(usr?.client)
		usr.client.running_find_references = null
	running_find_references = null

	//restart the garbage collector
	SSgarbage.can_fire = TRUE
	SSgarbage.update_nextfire(reset_time = TRUE)

/datum/proc/DoSearchVar(potential_container, container_name, recursive_limit = 64, search_time = world.time)
	#ifdef REFERENCE_TRACKING_DEBUG
	if(SSgarbage.should_save_refs && !found_refs)
		found_refs = list()
	#endif

	if(usr?.client && !usr.client.running_find_references)
		return

	if(!recursive_limit)
		log_reftracker("Recursion limit reached. [container_name]")
		return

	//Check each time you go down a layer. This makes it a bit slow, but it won't effect the rest of the game at all
	#ifndef FIND_REF_NO_CHECK_TICK
	CHECK_TICK
	#endif

	if(isdatum(potential_container))
		var/datum/datum_container = potential_container
		if(datum_container.last_find_references == search_time)
			return
#ifdef FAST_REFERENCE_TRACKING
		if(GLOB.reftracker_skip_typecache[datum_container.type])
			return
#endif

		datum_container.last_find_references = search_time
		var/container_print = datum_container.ref_search_details()
		var/list/vars_list = datum_container.vars

		for(var/varname in vars_list)
			#ifndef FIND_REF_NO_CHECK_TICK
			CHECK_TICK
			#endif
			if (varname == "vars" || varname == "vis_locs") //Fun fact, vis_locs don't count for references
				continue
			var/variable = vars_list[varname]

			if(variable == src)
				#ifdef REFERENCE_TRACKING_DEBUG
				if(SSgarbage.should_save_refs)
					found_refs[varname] = TRUE
					continue //End early, don't want these logging
				#endif
				log_reftracker("Found [type] [text_ref(src)] in [datum_container.type]'s [container_print] [varname] var. [container_name]")
				continue

			if(islist(variable))
				DoSearchVar(variable, "[container_name] [container_print] -> [varname] (list)", recursive_limit - 1, search_time)

	else if(islist(potential_container))
		var/normal = IS_NORMAL_LIST(potential_container)
		var/list/potential_cache = potential_container
		for(var/element_in_list in potential_cache)
			#ifndef FIND_REF_NO_CHECK_TICK
			CHECK_TICK
			#endif
			//Check normal entrys
			if(element_in_list == src)
				#ifdef REFERENCE_TRACKING_DEBUG
				if(SSgarbage.should_save_refs)
					found_refs[potential_cache] = TRUE
					continue //End early, don't want these logging
				#endif
				log_reftracker("Found [type] [text_ref(src)] in list [container_name].")
				continue

			var/assoc_val = null
			if(!isnum(element_in_list) && normal)
				assoc_val = potential_cache[element_in_list]
			//Check assoc entrys
			if(assoc_val == src)
				#ifdef REFERENCE_TRACKING_DEBUG
				if(SSgarbage.should_save_refs)
					found_refs[potential_cache] = TRUE
					continue //End early, don't want these logging
				#endif
				log_reftracker("Found [type] [text_ref(src)] in list [container_name]\[[element_in_list]\]")
				continue
			//We need to run both of these checks, since our object could be hiding in either of them
			//Check normal sublists
			if(islist(element_in_list))
				DoSearchVar(element_in_list, "[container_name] -> [element_in_list] (list)", recursive_limit - 1, search_time)
			//Check assoc sublists
			if(islist(assoc_val))
				DoSearchVar(potential_container[element_in_list], "[container_name]\[[element_in_list]\] -> [assoc_val] (list)", recursive_limit - 1, search_time)

/proc/qdel_and_find_ref_if_fail(datum/thing_to_del, force = FALSE)
	thing_to_del.qdel_and_find_ref_if_fail(force)

/datum/proc/qdel_and_find_ref_if_fail(force = FALSE)
	SSgarbage.reference_find_on_fail[text_ref(src)] = TRUE
	qdel(src, force)

#endif

// Kept outside the ifdef so overrides are easy to implement

/// Return info about us for reference searching purposes
/// Will be logged as a representation of this datum if it's a part of a search chain
/datum/proc/ref_search_details()
	return text_ref(src)

/datum/callback/ref_search_details()
	return "[text_ref(src)] (obj: [object] proc: [delegate] args: [json_encode(arguments)] user: [user?.resolve() || "null"])"
