-- Add shared_by column to session_groups table to track who shared the session
ALTER TABLE session_groups ADD COLUMN shared_by UUID REFERENCES auth.users(id) DEFAULT auth.uid();

-- Create a policy to allow updating shared_by
CREATE POLICY "Users can set shared_by when sharing sessions" ON session_groups
  FOR INSERT WITH CHECK (shared_by = auth.uid());

-- Update existing records to have the session owner as the sharer
UPDATE session_groups SET shared_by = sessions.user_id
FROM sessions
WHERE session_groups.session_id = sessions.id;
