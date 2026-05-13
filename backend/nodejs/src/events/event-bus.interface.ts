export interface DomainEvent {
  type: string
  payload: unknown
  occurredAt: Date
}

export interface DomainEventBus {
  publish(event: DomainEvent): Promise<void>
}

export class NoOpEventBus implements DomainEventBus {
  async publish(_event: DomainEvent): Promise<void> {
    // no-op; swap for KafkaEventBus in index.ts
  }
}
