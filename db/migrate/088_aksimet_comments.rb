class AksimetComments < ActiveRecord::Migration
  def self.up
    add_column(:comments, :spam, :boolean, {:default => false})
    Comment.update_all('spam=0')
  end

  def self.down
    remove_column(:comments, :spam)
  end
end
