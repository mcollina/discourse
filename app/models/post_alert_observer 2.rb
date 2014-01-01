require 'koala'

# THIS FILE HAS BEEN MODIFIED TO POST TO A FACEBOOK GROUP FOR EVERY NEW TOPIC
# TO-DO:
#  - Post comments
#  - Post likes
#  - Force users to auth with FB

# Methods changed:
#  - after_create_post
# Methods added:
#  - post_to_fb_group

class PostAlertObserver < ActiveRecord::Observer
  observe :post, :post_action, :post_revision

  # Dispatch to an after_save_#{class_name} method
  def after_save(model)
    method_name = callback_for('after_save', model)
    send(method_name, model) if respond_to?(method_name)
  end

  # Dispatch to an after_create_#{class_name} method
  def after_create(model)
    method_name = callback_for('after_create', model)
    send(method_name, model) if respond_to?(method_name)
  end

  # We need to consider new people to mention / quote when a post is edited
  def after_save_post(post)
    return if post.topic.private_message?

    mentioned_users = extract_mentioned_users(post)
    quoted_users = extract_quoted_users(post)

    reply_to_user = post.reply_notification_target
    notify_users(mentioned_users - [reply_to_user], :mentioned, post)
    notify_users(quoted_users - mentioned_users - [reply_to_user], :quoted, post)
  end

  def after_save_post_action(post_action)
    # We only care about deleting post actions for now
    return if post_action.deleted_at.blank?
    Notification.where(post_action_id: post_action.id).each(&:destroy)
  end

  def after_create_post_action(post_action)
    # We only notify on likes for now
    return unless post_action.is_like?

    post = post_action.post
    return if post_action.user.blank?
    return if post.topic.private_message?

    create_notification(post.user,
                        Notification.types[:liked],
                        post,
                        display_username: post_action.user.username,
                        post_action_id: post_action.id)
  end

  def after_create_post_revision(post_revision)
    post = post_revision.post

    return if post_revision.user.blank?
    return if post_revision.user_id == post.user_id
    return if post.topic.private_message?

    create_notification(post.user, Notification.types[:edited], post, display_username: post_revision.user.username)
  end

  # def after_create_post(post)
  #   if post.topic.private_message?
  #     # If it's a private message, notify the topic_allowed_users
  #     post.topic.all_allowed_users.reject{ |a| a.id == post.user_id }.each do |a|
  #       create_notification(a, Notification.types[:private_message], post)
  #     end
  #   elsif post.post_type != Post.types[:moderator_action]
  #     # If it's not a private message and it's not an automatic post caused by a moderator action, notify the users
  #     notify_post_users(post)
  #   end
  # end


  def after_create_post(post)
    if post.topic.private_message?
        # If it's a private message, notify the topic_allowed_users
        post.topic.all_allowed_users.reject{ |a| a.id == post.user_id }.each do |a|
          create_notification(a, Notification.types[:private_message], post)
        end
    elsif post.post_type != Post.types[:moderator_action]
        # If it's not a private message and it's not an automatic post caused by a moderator action, notify the users
        notify_post_users(post)
        if post.post_number == 1 && post.topic
          post_to_fb_group(post.topic)
        end
    end
end

  protected

    def post_to_fb_group(topic)

      group_id = ENV['FB_GROUP_ID']
      bot_access_token = ENV['FB_BOT_TOKEN']

      permalink = "http://startupscene.org/t/" + topic.slug

      if topic.user.facebook_user_info.token #then we'll post on their behalf
        graph = Koala::Facebook::GraphAPI.new(topic.user.facebook_user_info.token)
      else #we'll post with our bot
        graph = Koala::Facebook::GraphAPI.new(bot_access_token)
      end
        graph.put_object(group_id, "feed", :message => topic.posts.first.raw, :link => permalink, :image => 'https://s3-eu-west-1.amazonaws.com/italianstartupscene/iss-logo.png')
    end

    def callback_for(action, model)
      "#{action}_#{model.class.name.underscore.gsub(/.+\//, '')}"
    end

    def create_notification(user, type, post, opts={})
      return if user.blank?

      # Make sure the user can see the post
      return unless Guardian.new(user).can_see?(post)

      # skip if muted on the topic
      return if TopicUser.get(post.topic, user).try(:notification_level) == TopicUser.notification_levels[:muted]

      # Don't notify the same user about the same notification on the same post
      return if user.notifications.exists?(notification_type: type, topic_id: post.topic_id, post_number: post.post_number)

      # Create the notification
      user.notifications.create(notification_type: type,
                                topic_id: post.topic_id,
                                post_number: post.post_number,
                                post_action_id: opts[:post_action_id],
                                data: { topic_title: post.topic.title,
                                        display_username: opts[:display_username] || post.user.username }.to_json)
    end

    # TODO: Move to post-analyzer?
    # Returns a list users who have been mentioned
    def extract_mentioned_users(post)
      User.where(username_lower: post.raw_mentions).where("id <> ?", post.user_id)
    end

    # TODO: Move to post-analyzer?
    # Returns a list of users who were quoted in the post
    def extract_quoted_users(post)
      post.raw.scan(/\[quote=\"([^,]+),.+\"\]/).uniq.map do |m|
        User.where("username_lower = :username and id != :id", username: m.first.strip.downcase, id: post.user_id).first
      end.compact
    end

    # Notify a bunch of users
    def notify_users(users, type, post)
      users = [users] unless users.is_a?(Array)
      users.each do |u|
        create_notification(u, Notification.types[type], post)
      end
    end

    # TODO: This should use javascript for parsing rather than re-doing it this way.
    def notify_post_users(post)
      # Is this post a reply to a user?
      reply_to_user = post.reply_notification_target
      notify_users(reply_to_user, :replied, post)

      exclude_user_ids = []
      exclude_user_ids << post.user_id
      exclude_user_ids << reply_to_user.id if reply_to_user.present?
      exclude_user_ids << extract_mentioned_users(post).map(&:id)
      exclude_user_ids << extract_quoted_users(post).map(&:id)
      exclude_user_ids.flatten!
      TopicUser
        .where(topic_id: post.topic_id, notification_level: TopicUser.notification_levels[:watching])
        .includes(:user).each do |tu|
          create_notification(tu.user, Notification.types[:posted], post) unless exclude_user_ids.include?(tu.user_id)
        end
    end
end
