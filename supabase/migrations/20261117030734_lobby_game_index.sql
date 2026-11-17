-- Cover the catalog foreign key used when deleting/updating game definitions.
create index lobbies_game_idx on game_private.lobbies (game_id);
