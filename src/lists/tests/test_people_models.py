from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.test import TestCase

from app.models import Item, MediaTypes, Sources
from lists.models import CustomList, CustomListItem, PersonListItem


class PeopleListModelTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="people-list-owner",
            password="password",
        )
        self.collaborator = get_user_model().objects.create_user(
            username="people-list-collaborator",
            password="password",
        )
        self.media_list = CustomList.objects.create(
            owner=self.user,
            name="Media",
        )
        self.people_list = CustomList.objects.create(
            owner=self.user,
            name="People",
            list_type=CustomList.ListType.PEOPLE,
        )
        self.people_list.collaborators.add(self.collaborator)
        self.item = Item.objects.create(
            source=Sources.TMDB,
            media_type=MediaTypes.MOVIE,
            media_id="movie-1",
            title="Movie",
            image="https://example.com/movie.jpg",
        )

    def test_list_type_defaults_and_database_constraint(self):
        self.assertEqual(self.media_list.list_type, CustomList.ListType.MEDIA)
        self.assertEqual(
            CustomList._meta.get_field("list_type").db_default,
            CustomList.ListType.MEDIA,
        )

        with self.assertRaises(IntegrityError), transaction.atomic():
            CustomList.objects.filter(pk=self.media_list.pk).update(
                list_type="mixed",
            )

    def test_person_identity_is_unique_per_list_and_source(self):
        person = PersonListItem.objects.create(
            custom_list=self.people_list,
            source=PersonListItem.Source.TMDB,
            person_id="31",
            name="Tom Hanks",
        )

        with self.assertRaises(IntegrityError), transaction.atomic():
            PersonListItem.objects.create(
                custom_list=self.people_list,
                source=person.source,
                person_id=person.person_id,
                name=person.name,
            )

        other_source = PersonListItem.objects.create(
            custom_list=self.people_list,
            source=PersonListItem.Source.MAL,
            person_id=person.person_id,
            name=person.name,
        )
        other_list = CustomList.objects.create(
            owner=self.user,
            name="Other People",
            list_type=CustomList.ListType.PEOPLE,
        )
        other_membership = PersonListItem.objects.create(
            custom_list=other_list,
            source=person.source,
            person_id=person.person_id,
            name=person.name,
        )

        self.assertNotEqual(person.pk, other_source.pk)
        self.assertNotEqual(person.pk, other_membership.pk)

    def test_people_ordering_and_list_image_use_snapshots(self):
        later = PersonListItem.objects.create(
            custom_list=self.people_list,
            source=PersonListItem.Source.TMDB,
            person_id="2",
            name="Second",
            profile_url="https://example.com/second.jpg",
            position=2,
        )
        first = PersonListItem.objects.create(
            custom_list=self.people_list,
            source=PersonListItem.Source.TMDB,
            person_id="1",
            name="First",
            profile_url="https://example.com/first.jpg",
            position=1,
        )

        self.assertEqual(list(self.people_list.person_items.all()), [first, later])
        self.assertEqual(self.people_list.image, first.profile_url)

        empty_people_list = CustomList.objects.create(
            owner=self.user,
            name="Empty People",
            list_type=CustomList.ListType.PEOPLE,
        )
        self.assertEqual(empty_people_list.image, settings.IMG_NONE)

    def test_media_image_behavior_is_unchanged(self):
        CustomListItem.objects.create(
            custom_list=self.media_list,
            item=self.item,
        )

        self.assertEqual(self.media_list.image, self.item.image)

    def test_membership_managers_only_return_matching_list_types(self):
        CustomListItem.objects.create(
            custom_list=self.media_list,
            item=self.item,
        )
        PersonListItem.objects.create(
            custom_list=self.people_list,
            source=PersonListItem.Source.TMDB,
            person_id="31",
            name="Tom Hanks",
        )

        media_lists = list(
            CustomList.objects.get_user_lists_with_item(self.user, self.item),
        )
        people_lists = list(
            CustomList.objects.get_user_lists_with_person(
                self.collaborator,
                PersonListItem.Source.TMDB,
                "31",
            ),
        )

        self.assertEqual(media_lists, [self.media_list])
        self.assertTrue(media_lists[0].has_item)
        self.assertEqual(people_lists, [self.people_list])
        self.assertTrue(people_lists[0].has_person)
