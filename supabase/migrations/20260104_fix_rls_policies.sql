-- ============================================================================
-- COMPREHENSIVE RLS POLICY FIX FOR DATA ISOLATION
-- This migration ensures all data is properly isolated by user_id
-- ============================================================================

-- First, enable RLS on all tables (if not already enabled)
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE players ENABLE ROW LEVEL SECURITY;
ALTER TABLE rebuys ENABLE ROW LEVEL SECURITY;
ALTER TABLE groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE quick_add_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- DROP ALL EXISTING POLICIES (to start fresh)
-- ============================================================================

-- Sessions policies
DROP POLICY IF EXISTS "Users can view own sessions" ON sessions;
DROP POLICY IF EXISTS "Users can insert own sessions" ON sessions;
DROP POLICY IF EXISTS "Users can update own sessions" ON sessions;
DROP POLICY IF EXISTS "Users can delete own sessions" ON sessions;
DROP POLICY IF EXISTS "Users can view shared sessions" ON sessions;

-- Session players policies
DROP POLICY IF EXISTS "Users can view session players for own sessions" ON session_players;
DROP POLICY IF EXISTS "Users can insert session players for own sessions" ON session_players;
DROP POLICY IF EXISTS "Users can update session players for own sessions" ON session_players;
DROP POLICY IF EXISTS "Users can delete session players for own sessions" ON session_players;
DROP POLICY IF EXISTS "Users can view session players for shared sessions" ON session_players;

-- Players policies
DROP POLICY IF EXISTS "Users can view own players" ON players;
DROP POLICY IF EXISTS "Users can insert own players" ON players;
DROP POLICY IF EXISTS "Users can update own players" ON players;
DROP POLICY IF EXISTS "Users can delete own players" ON players;

-- Rebuys policies
DROP POLICY IF EXISTS "Users can view rebuys for own sessions" ON rebuys;
DROP POLICY IF EXISTS "Users can insert rebuys for own sessions" ON rebuys;
DROP POLICY IF EXISTS "Users can update rebuys for own sessions" ON rebuys;
DROP POLICY IF EXISTS "Users can delete rebuys for own sessions" ON rebuys;

-- Groups policies
DROP POLICY IF EXISTS "Users can view own groups" ON groups;
DROP POLICY IF EXISTS "Users can view member groups" ON groups;
DROP POLICY IF EXISTS "Users can insert own groups" ON groups;
DROP POLICY IF EXISTS "Users can update own groups" ON groups;
DROP POLICY IF EXISTS "Users can delete own groups" ON groups;

-- Group members policies
DROP POLICY IF EXISTS "Users can view group members" ON group_members;
DROP POLICY IF EXISTS "Group owners can insert members" ON group_members;
DROP POLICY IF EXISTS "Group owners can delete members" ON group_members;
DROP POLICY IF EXISTS "Members can delete themselves" ON group_members;

-- Session groups policies
DROP POLICY IF EXISTS "Users can view session groups" ON session_groups;
DROP POLICY IF EXISTS "Users can insert session groups" ON session_groups;
DROP POLICY IF EXISTS "Users can delete session groups" ON session_groups;
DROP POLICY IF EXISTS "Users can set shared_by when sharing sessions" ON session_groups;

-- Quick add entries policies
DROP POLICY IF EXISTS "Users can view own quick add entries" ON quick_add_entries;
DROP POLICY IF EXISTS "Users can insert own quick add entries" ON quick_add_entries;
DROP POLICY IF EXISTS "Users can update own quick add entries" ON quick_add_entries;
DROP POLICY IF EXISTS "Users can delete own quick add entries" ON quick_add_entries;

-- Profiles policies
DROP POLICY IF EXISTS "Users can view all profiles" ON profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON profiles;
DROP POLICY IF EXISTS "Users can insert own profile" ON profiles;

-- ============================================================================
-- SESSIONS TABLE POLICIES
-- ============================================================================

-- Users can only view their own sessions OR sessions shared to groups they belong to
CREATE POLICY "Users can view own sessions" ON sessions
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Users can view shared sessions" ON sessions
  FOR SELECT USING (
    id IN (
      SELECT sg.session_id FROM session_groups sg
      WHERE sg.group_id IN (
        -- Groups user owns
        SELECT g.id FROM groups g WHERE g.owner_id = auth.uid()
        UNION
        -- Groups user is a member of
        SELECT gm.group_id FROM group_members gm WHERE gm.user_id = auth.uid()
      )
    )
  );

CREATE POLICY "Users can insert own sessions" ON sessions
  FOR INSERT WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own sessions" ON sessions
  FOR UPDATE USING (user_id = auth.uid());

CREATE POLICY "Users can delete own sessions" ON sessions
  FOR DELETE USING (user_id = auth.uid());

-- ============================================================================
-- SESSION_PLAYERS TABLE POLICIES
-- ============================================================================

-- Users can view session players for sessions they own
CREATE POLICY "Users can view session players for own sessions" ON session_players
  FOR SELECT USING (
    session_id IN (SELECT id FROM sessions WHERE user_id = auth.uid())
  );

-- Users can view session players for shared sessions
CREATE POLICY "Users can view session players for shared sessions" ON session_players
  FOR SELECT USING (
    session_id IN (
      SELECT sg.session_id FROM session_groups sg
      WHERE sg.group_id IN (
        SELECT g.id FROM groups g WHERE g.owner_id = auth.uid()
        UNION
        SELECT gm.group_id FROM group_members gm WHERE gm.user_id = auth.uid()
      )
    )
  );

CREATE POLICY "Users can insert session players for own sessions" ON session_players
  FOR INSERT WITH CHECK (
    session_id IN (SELECT id FROM sessions WHERE user_id = auth.uid())
  );

CREATE POLICY "Users can update session players for own sessions" ON session_players
  FOR UPDATE USING (
    session_id IN (SELECT id FROM sessions WHERE user_id = auth.uid())
  );

CREATE POLICY "Users can delete session players for own sessions" ON session_players
  FOR DELETE USING (
    session_id IN (SELECT id FROM sessions WHERE user_id = auth.uid())
  );

-- ============================================================================
-- PLAYERS TABLE POLICIES
-- ============================================================================

-- Users can only view their own players
CREATE POLICY "Users can view own players" ON players
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Users can insert own players" ON players
  FOR INSERT WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own players" ON players
  FOR UPDATE USING (user_id = auth.uid());

CREATE POLICY "Users can delete own players" ON players
  FOR DELETE USING (user_id = auth.uid());

-- ============================================================================
-- REBUYS TABLE POLICIES
-- ============================================================================

-- Users can view rebuys for session players in their own sessions
CREATE POLICY "Users can view rebuys for own sessions" ON rebuys
  FOR SELECT USING (
    session_player_id IN (
      SELECT sp.id FROM session_players sp
      JOIN sessions s ON sp.session_id = s.id
      WHERE s.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can insert rebuys for own sessions" ON rebuys
  FOR INSERT WITH CHECK (
    session_player_id IN (
      SELECT sp.id FROM session_players sp
      JOIN sessions s ON sp.session_id = s.id
      WHERE s.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can update rebuys for own sessions" ON rebuys
  FOR UPDATE USING (
    session_player_id IN (
      SELECT sp.id FROM session_players sp
      JOIN sessions s ON sp.session_id = s.id
      WHERE s.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can delete rebuys for own sessions" ON rebuys
  FOR DELETE USING (
    session_player_id IN (
      SELECT sp.id FROM session_players sp
      JOIN sessions s ON sp.session_id = s.id
      WHERE s.user_id = auth.uid()
    )
  );

-- ============================================================================
-- GROUPS TABLE POLICIES
-- ============================================================================

-- Users can view groups they own
CREATE POLICY "Users can view own groups" ON groups
  FOR SELECT USING (owner_id = auth.uid());

-- Users can view groups they are members of
CREATE POLICY "Users can view member groups" ON groups
  FOR SELECT USING (
    id IN (SELECT group_id FROM group_members WHERE user_id = auth.uid())
  );

CREATE POLICY "Users can insert own groups" ON groups
  FOR INSERT WITH CHECK (owner_id = auth.uid());

CREATE POLICY "Users can update own groups" ON groups
  FOR UPDATE USING (owner_id = auth.uid());

CREATE POLICY "Users can delete own groups" ON groups
  FOR DELETE USING (owner_id = auth.uid());

-- ============================================================================
-- GROUP_MEMBERS TABLE POLICIES
-- ============================================================================

-- Users can view members of groups they own or are members of
CREATE POLICY "Users can view group members" ON group_members
  FOR SELECT USING (
    group_id IN (
      SELECT id FROM groups WHERE owner_id = auth.uid()
      UNION
      SELECT group_id FROM group_members WHERE user_id = auth.uid()
    )
  );

-- Group owners can add members
CREATE POLICY "Group owners can insert members" ON group_members
  FOR INSERT WITH CHECK (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
  );

-- Group owners can remove members
CREATE POLICY "Group owners can delete members" ON group_members
  FOR DELETE USING (
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
  );

-- Members can remove themselves
CREATE POLICY "Members can delete themselves" ON group_members
  FOR DELETE USING (user_id = auth.uid());

-- ============================================================================
-- SESSION_GROUPS TABLE POLICIES
-- ============================================================================

-- Users can view session_groups for groups they belong to
CREATE POLICY "Users can view session groups" ON session_groups
  FOR SELECT USING (
    group_id IN (
      SELECT id FROM groups WHERE owner_id = auth.uid()
      UNION
      SELECT group_id FROM group_members WHERE user_id = auth.uid()
    )
  );

-- Users can share their own sessions to groups they belong to
CREATE POLICY "Users can insert session groups" ON session_groups
  FOR INSERT WITH CHECK (
    -- Must own the session
    session_id IN (SELECT id FROM sessions WHERE user_id = auth.uid())
    AND
    -- Must be owner or member of the group
    group_id IN (
      SELECT id FROM groups WHERE owner_id = auth.uid()
      UNION
      SELECT group_id FROM group_members WHERE user_id = auth.uid()
    )
    AND
    -- shared_by must be the current user
    shared_by = auth.uid()
  );

-- Users can remove sessions they shared OR group owners can remove any session
CREATE POLICY "Users can delete session groups" ON session_groups
  FOR DELETE USING (
    shared_by = auth.uid()
    OR
    group_id IN (SELECT id FROM groups WHERE owner_id = auth.uid())
  );

-- ============================================================================
-- QUICK_ADD_ENTRIES TABLE POLICIES
-- ============================================================================

-- Users can only view their own quick add entries
CREATE POLICY "Users can view own quick add entries" ON quick_add_entries
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Users can insert own quick add entries" ON quick_add_entries
  FOR INSERT WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own quick add entries" ON quick_add_entries
  FOR UPDATE USING (user_id = auth.uid());

CREATE POLICY "Users can delete own quick add entries" ON quick_add_entries
  FOR DELETE USING (user_id = auth.uid());

-- ============================================================================
-- PROFILES TABLE POLICIES
-- ============================================================================

-- All authenticated users can view profiles (for display names, linking players)
CREATE POLICY "Users can view all profiles" ON profiles
  FOR SELECT USING (auth.role() = 'authenticated');

-- Users can only update their own profile
CREATE POLICY "Users can update own profile" ON profiles
  FOR UPDATE USING (id = auth.uid());

-- Users can insert their own profile
CREATE POLICY "Users can insert own profile" ON profiles
  FOR INSERT WITH CHECK (id = auth.uid());

-- ============================================================================
-- APP_SETTINGS TABLE (for maintenance mode)
-- ============================================================================

-- Create app_settings table if it doesn't exist
CREATE TABLE IF NOT EXISTS app_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

-- Everyone can read app settings
CREATE POLICY "Anyone can read app settings" ON app_settings
  FOR SELECT USING (true);

-- Only admins can modify app settings (we'll check admin status in the app)
-- For now, allow authenticated users to update (app will enforce admin check)
CREATE POLICY "Authenticated users can update app settings" ON app_settings
  FOR UPDATE USING (auth.role() = 'authenticated');

CREATE POLICY "Authenticated users can insert app settings" ON app_settings
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');
