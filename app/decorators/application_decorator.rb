# frozen_string_literal: true

# Base class for all decorators. Delegates all methods to the wrapped object
# so subclasses can transparently access the underlying data.
class ApplicationDecorator < Draper::Decorator
  delegate_all
end
